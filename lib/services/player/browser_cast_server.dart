import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:kazumi/services/logging/logger.dart';

/// 浏览器投屏：在本机开一个 HTTP 服务，电视（或手机）浏览器打开首页后，
/// 页面通过 MSE (hls.js) 播放本机转发的视频流。
///
/// 适用于 DLNA 推送被电视拒绝、但浏览器可用的智能电视（如三星 Tizen）。
/// 视频流经本机转发，解决 Referer / UA / 跨域限制，m3u8 内的地址会被改写回本机。
/// 一些电视浏览器只允许访问 80/443 端口，因此优先绑定 80。
///
/// `/api/now` 与 `/api/report` 是播放页面的最小协议；其余 `/api/*` 交给
/// [apiHandler]（远程控制接口，见 KazumiRemoteApi）。
class BrowserCastSession {
  final int generation;
  final String url;
  final Map<String, String> headers;
  final String title;
  final int startSeconds;

  /// 'hls' 走 hls.js (MSE)，'media' 交给 `<video src>` 原生播放。
  final Future<String> kind;

  /// 本机转码输出目录（HLS 文件）；非空时从 `/t/<gen>/` 提供，忽略 [url]。
  final String? localDir;

  BrowserCastSession({
    required this.generation,
    required this.url,
    required this.headers,
    required this.title,
    required this.startSeconds,
    required this.kind,
    this.localDir,
  });
}

typedef RemoteApiHandler = Future<bool> Function(HttpRequest request);

class BrowserCastServer {
  BrowserCastServer._();

  static final BrowserCastServer instance = BrowserCastServer._();

  static const List<int> candidatePorts = [80, 8080];
  static const String _indexAsset = 'assets/web/index.html';
  static const String _hlsAsset = 'assets/web/hls.min.js';

  HttpServer? _server;
  int? port;
  int _generation = 0;
  BrowserCastSession? _session;
  Uint8List? _hlsJs;
  String? _index;

  /// 处理 `/api/*`（除 now/report 以外）的扩展接口；返回 false 表示未处理。
  RemoteApiHandler? apiHandler;

  /// 电视页面上报播放进度（秒）/ 播放结束时回调，由 cast() 重置。
  void Function(int seconds)? onProgress;
  void Function()? onEnded;

  /// 电视页面最近一次上报的状态，供投屏对话框展示。
  final ValueNotifier<String> status = ValueNotifier('等待电视打开页面');

  /// 电视最近上报的播放位置 / 总时长（秒）与播放状态。
  int lastPositionSeconds = 0;
  int lastDurationSeconds = 0;
  bool playing = false;

  int _commandSeq = 0;
  Map<String, Object>? _pendingCommand;

  final HttpClient _client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 15);

  bool get isRunning => _server != null;

  BrowserCastSession? get session => _session;

  Future<void> start() async {
    if (_server != null) {
      return;
    }
    Object? lastError;
    for (final candidate in candidatePorts) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, candidate);
        port = candidate;
        _server!.listen(_handle, onError: (Object e) {
          KazumiLogger().e('BrowserCast: server error', error: e);
        });
        KazumiLogger().i('BrowserCast: listening on port $candidate');
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('端口 ${candidatePorts.join('/')} 均不可用: $lastError');
  }

  Future<void> stop() async {
    _session = null;
    final server = _server;
    _server = null;
    port = null;
    await server?.close(force: true);
  }

  /// 切换电视正在播放的内容。页面每 2 秒轮询一次，发现 generation 变化即切换。
  void cast({
    required String url,
    required Map<String, String> headers,
    required String title,
    required int startSeconds,
    bool? isHls,
    String? localDir,
  }) {
    _generation++;
    status.value = '等待电视切换到新视频';
    lastPositionSeconds = startSeconds;
    lastDurationSeconds = 0;
    playing = false;
    onProgress = null;
    onEnded = null;
    _pendingCommand = null;
    _session = BrowserCastSession(
      generation: _generation,
      url: url,
      headers: headers,
      title: title,
      startSeconds: startSeconds,
      kind: localDir != null
          ? Future.value('hls')
          : _detectKind(url, headers, isHls),
      localDir: localDir,
    );
    KazumiLogger().i('BrowserCast: cast #$_generation $title $url');
  }

  void stopCasting() {
    _generation++;
    _session = null;
    onProgress = null;
    onEnded = null;
    status.value = '已停止投屏';
  }

  /// 给电视页面下发一条播放控制指令（play / pause / toggle / seek），页面取走后确认。
  void sendCommand(String action, {num? value}) {
    _pendingCommand = {
      'id': ++_commandSeq,
      'action': action,
      'value': ?value,
    };
  }

  /// 本机局域网地址，物理网卡优先，虚拟网卡（WSL / Tailscale / VPN）排后。
  Future<List<String>> addresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final virtual = RegExp(
        r'vEthernet|WSL|Tailscale|TAP|VMware|VirtualBox|Hyper-V|docker|zerotier|vpn',
        caseSensitive: false);
    final primary = <String>[];
    final secondary = <String>[];
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final a = addr.address;
        final second = int.tryParse(a.split('.')[1]) ?? 0;
        final cgnat = a.startsWith('100.') && second >= 64 && second <= 127;
        (virtual.hasMatch(iface.name) || cgnat ? secondary : primary).add(a);
      }
    }
    final suffix = port == 80 ? '' : ':$port';
    return [...primary, ...secondary].map((a) => 'http://$a$suffix/').toList();
  }

  Future<String> _detectKind(
      String url, Map<String, String> headers, bool? isHls) async {
    if (isHls == true || Uri.parse(url).path.toLowerCase().endsWith('.m3u8')) {
      return 'hls';
    }
    try {
      final req = await _client.headUrl(Uri.parse(url));
      headers.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 6));
      final type = res.headers.contentType?.mimeType.toLowerCase() ?? '';
      await res.drain<void>();
      if (type.contains('mpegurl')) {
        return 'hls';
      }
    } catch (_) {}
    return 'media';
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    try {
      if (path == '/' || path == '/index.html') {
        // 程序目录下的 web/index.html 优先，方便不重新打包就调整页面。
        final override = File(
            '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}web${Platform.pathSeparator}index.html');
        final page = await override.exists()
            ? await override.readAsString()
            : (_index ??= await rootBundle.loadString(_indexAsset));
        request.response.headers
            .set(HttpHeaders.cacheControlHeader, 'no-cache');
        _text(request.response, page, 'text/html; charset=utf-8');
      } else if (path == '/hls.min.js') {
        _hlsJs ??= (await rootBundle.load(_hlsAsset)).buffer.asUint8List();
        request.response.headers.contentType =
            ContentType('application', 'javascript', charset: 'utf-8');
        request.response.headers
            .set(HttpHeaders.cacheControlHeader, 'max-age=86400');
        request.response.contentLength = _hlsJs!.length;
        request.response.add(_hlsJs!);
      } else if (path == '/api/now') {
        await _now(request);
      } else if (path == '/api/report') {
        _report(request.uri.queryParameters);
        request.response.statusCode = HttpStatus.noContent;
      } else if (path.startsWith('/api/')) {
        final handled = await apiHandler?.call(request) ?? false;
        if (!handled) {
          request.response.statusCode = HttpStatus.notFound;
        }
      } else if (path.startsWith('/s/')) {
        await _stream(request);
      } else if (path.startsWith('/t/')) {
        await _localFile(request);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
    } catch (e, s) {
      KazumiLogger().e('BrowserCast: request $path failed',
          error: e, stackTrace: s);
      try {
        request.response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  void _report(Map<String, String> query) {
    final event = query['e'] ?? '';
    if (event.isEmpty) {
      return;
    }
    status.value = event;
    final seconds = int.tryParse(query['s'] ?? '');
    if (seconds != null) {
      lastPositionSeconds = seconds;
    }
    final duration = int.tryParse(query['d'] ?? '');
    if (duration != null && duration > 0) {
      lastDurationSeconds = duration;
    }
    if (event.startsWith('playing')) {
      playing = true;
      if (seconds != null) {
        onProgress?.call(seconds);
      }
      return;
    }
    if (event.startsWith('paused')) {
      playing = false;
      if (seconds != null) {
        onProgress?.call(seconds);
      }
      return;
    }
    KazumiLogger().i('BrowserCast: TV reports: $event');
    if (event.startsWith('ended') || event.startsWith('error')) {
      playing = false;
    }
    if (event.startsWith('ended')) {
      onEnded?.call();
    }
  }

  Future<void> _now(HttpRequest request) async {
    final ack = int.tryParse(request.uri.queryParameters['ack'] ?? '');
    if (ack != null && _pendingCommand?['id'] == ack) {
      _pendingCommand = null;
    }
    final session = _session;
    final Map<String, Object> body;
    if (session == null) {
      body = {'gen': 0};
    } else {
      final kind = await session.kind;
      final g = session.generation;
      final transcoded = session.localDir != null;
      body = {
        'gen': g,
        'title': session.title,
        'kind': kind,
        'start': session.startSeconds,
        'transcoded': transcoded,
        'src': transcoded
            ? '/t/$g/index.m3u8'
            : (kind == 'hls' ? '/s/$g/index.m3u8' : '/s/$g/media'),
      };
    }
    final command = _pendingCommand;
    if (command != null) {
      body['cmd'] = command;
    }
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    _text(request.response, jsonEncode(body), 'application/json');
  }

  void _text(HttpResponse response, String body, String contentType) {
    final bytes = utf8.encode(body);
    response.headers.set(HttpHeaders.contentTypeHeader, contentType);
    response.contentLength = bytes.length;
    response.add(bytes);
  }

  /// `/s/<gen>/index.m3u8`、`/s/<gen>/media`、`/s/<gen>/u?u=<绝对地址>`
  Future<void> _stream(HttpRequest request) async {
    final parts = request.uri.pathSegments;
    final session = _session;
    if (parts.length != 3 ||
        session == null ||
        int.tryParse(parts[1]) != session.generation) {
      request.response.statusCode = HttpStatus.gone;
      return;
    }
    final target = parts[2] == 'u'
        ? (request.uri.queryParameters['u'] ?? '')
        : session.url;
    if (target.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      return;
    }
    final upstream = Uri.parse(target);
    final req = await _client.openUrl(request.method, upstream);
    session.headers.forEach(req.headers.set);
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      req.headers.set(HttpHeaders.rangeHeader, range);
    }
    final res = await req.close();
    final mime = res.headers.contentType?.mimeType.toLowerCase() ?? '';
    final isPlaylist = parts[2] == 'index.m3u8' ||
        mime.contains('mpegurl') ||
        upstream.path.toLowerCase().endsWith('.m3u8');
    final response = request.response;

    if (isPlaylist) {
      var bytes = await _collect(res);
      if (res.headers.value(HttpHeaders.contentEncodingHeader) == 'gzip') {
        bytes = gzip.decode(bytes);
      }
      final rewritten = _rewritePlaylist(
          utf8.decode(bytes, allowMalformed: true),
          upstream,
          session.generation);
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      _text(response, rewritten, 'application/vnd.apple.mpegurl');
      return;
    }

    response.statusCode = res.statusCode;
    for (final name in [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
    ]) {
      final value = res.headers.value(name);
      if (value != null) {
        response.headers.set(name, value);
      }
    }
    if (request.method == 'HEAD') {
      await res.drain<void>();
      return;
    }
    await response.addStream(res);
  }

  /// `/t/<gen>/index.m3u8`、`/t/<gen>/segNNNNN.ts`：本机转码输出。
  Future<void> _localFile(HttpRequest request) async {
    final parts = request.uri.pathSegments;
    final session = _session;
    final dir = session?.localDir;
    if (parts.length != 3 ||
        session == null ||
        dir == null ||
        int.tryParse(parts[1]) != session.generation) {
      request.response.statusCode = HttpStatus.gone;
      return;
    }
    final name = parts[2];
    if (name.contains('/') || name.contains('\\') || name.contains('..')) {
      request.response.statusCode = HttpStatus.badRequest;
      return;
    }
    final file = File('$dir${Platform.pathSeparator}$name');
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      return;
    }
    final response = request.response;
    if (name.endsWith('.m3u8')) {
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      _text(response, await file.readAsString(), 'application/vnd.apple.mpegurl');
      return;
    }
    response.headers.contentType = ContentType('video', 'mp2t');
    response.headers.set(HttpHeaders.cacheControlHeader, 'max-age=3600');
    response.contentLength = await file.length();
    if (request.method == 'HEAD') {
      return;
    }
    await response.addStream(file.openRead());
  }

  Future<List<int>> _collect(HttpClientResponse res) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  String _rewritePlaylist(String text, Uri base, int generation) {
    String local(String raw) =>
        '/s/$generation/u?u=${Uri.encodeQueryComponent(base.resolve(raw.trim()).toString())}';
    final uriAttr = RegExp(r'URI="([^"]+)"');
    final out = <String>[];
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        out.add(line);
      } else if (!trimmed.startsWith('#')) {
        out.add(local(trimmed));
      } else {
        out.add(trimmed.replaceAllMapped(
            uriAttr, (m) => 'URI="${local(m.group(1)!)}"'));
      }
    }
    return '${out.join('\n')}\n';
  }
}
