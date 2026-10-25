import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/browser_cast_server.dart';

/// Upstream stand-in: a playlist that requires a Referer, a segment that honours
/// Range requests, and a record of what the proxy actually sent.
class _Upstream {
  late final HttpServer server;
  final Map<String, String> referers = {};
  final List<int> segment = List<int>.generate(1000, (i) => i % 256);

  Uri get base => Uri.parse('http://127.0.0.1:${server.port}/');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      referers[req.uri.path] = req.headers.value('referer') ?? '';
      final res = req.response;
      switch (req.uri.path) {
        case '/v/playlist.m3u8':
          res.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          res.write('#EXTM3U\n'
              '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
              '#EXTINF:4,\n0000.ts\n'
              '#EXTINF:4,\nhttps://cdn.example/abs/0001.ts\n');
        case '/v/0000.ts':
          res.headers.contentType = ContentType('video', 'mp2t');
          final range = req.headers.value('range');
          if (range == null) {
            res.contentLength = segment.length;
            res.add(segment);
          } else {
            final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
            final s = int.parse(m.group(1)!);
            final e = m.group(2)!.isEmpty
                ? segment.length - 1
                : int.parse(m.group(2)!);
            res.statusCode = HttpStatus.partialContent;
            res.headers.set('content-range', 'bytes $s-$e/${segment.length}');
            res.contentLength = e - s + 1;
            res.add(segment.sublist(s, e + 1));
          }
        default:
          res.statusCode = HttpStatus.notFound;
      }
      await res.close();
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Upstream upstream;
  late BrowserCastServer cast;
  late HttpClient client;

  Future<HttpClientResponse> get(String path, {String? range}) async {
    final req = await client
        .getUrl(Uri.parse('http://127.0.0.1:${cast.port}$path'));
    if (range != null) {
      req.headers.set('range', range);
    }
    return req.close();
  }

  Future<String> body(HttpClientResponse res) => utf8.decodeStream(res);

  setUpAll(() async {
    // flutter_test installs a mock HttpClient; this test needs real sockets.
    HttpOverrides.global = null;
    cast = BrowserCastServer.instance;
    client = HttpClient();
    upstream = _Upstream();
    await upstream.start();
    await cast.start();
  });

  tearDownAll(() async {
    await cast.stop();
    await upstream.server.close(force: true);
    client.close(force: true);
  });

  test('binds a candidate port and serves the player page', () async {
    expect(BrowserCastServer.candidatePorts, contains(cast.port));
    final res = await get('/');
    expect(res.statusCode, 200);
    expect(await body(res), contains('<title>Kazumi</title>'));
    final now = jsonDecode(await body(await get('/api/now'))) as Map;
    expect(now['gen'], 0);
  });

  test('proxies and rewrites an HLS session with upstream headers', () async {
    cast.cast(
      url: upstream.base.resolve('v/playlist.m3u8').toString(),
      headers: {'referer': 'https://ref.example/'},
      title: 'ep1',
      startSeconds: 7,
    );
    final now = jsonDecode(await body(await get('/api/now'))) as Map;
    expect(now['kind'], 'hls');
    expect(now['title'], 'ep1');
    expect(now['start'], 7);
    final gen = now['gen'] as int;
    expect(now['src'], '/s/$gen/index.m3u8');

    final res = await get('/s/$gen/index.m3u8');
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'application/vnd.apple.mpegurl');
    final playlist = await body(res);
    final seg = Uri.encodeQueryComponent(
        upstream.base.resolve('v/0000.ts').toString());
    expect(playlist, contains('\n/s/$gen/u?u=$seg\n'));
    expect(playlist, contains('/s/$gen/u?u=https%3A%2F%2Fcdn.example%2Fabs%2F0001.ts'));
    expect(playlist, contains('URI="/s/$gen/u?u=${Uri.encodeQueryComponent(upstream.base.resolve('v/key.bin').toString())}"'));
    expect(upstream.referers['/v/playlist.m3u8'], 'https://ref.example/');

    final part = await get('/s/$gen/u?u=$seg', range: 'bytes=10-19');
    expect(part.statusCode, HttpStatus.partialContent);
    expect(part.headers.value('content-range'), 'bytes 10-19/1000');
    final bytes = await part.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(bytes, upstream.segment.sublist(10, 20));
    expect(upstream.referers['/v/0000.ts'], 'https://ref.example/');

    final stale = await get('/s/${gen - 1}/index.m3u8');
    expect(stale.statusCode, HttpStatus.gone);
    await stale.drain<void>();
  });

  test('stopCasting returns the page to idle', () async {
    cast.stopCasting();
    final now = jsonDecode(await body(await get('/api/now'))) as Map;
    expect(now['gen'], 0);
  });
}
