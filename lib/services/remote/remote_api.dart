import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/browser_cast_server.dart';
import 'package:kazumi/services/remote/transcode_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';
import 'package:kazumi/services/video_source/video_source_resolver_pool.dart';
import 'package:kazumi/utils/episode_url.dart';

/// 浏览器投屏页面用的远程控制接口：搜索番剧、查片源、选集、解析并投到电视、
/// 读写收藏与历史。全部挂在 [BrowserCastServer] 的 `/api/*` 下。
class KazumiRemoteApi {
  KazumiRemoteApi._(this.server);

  static final KazumiRemoteApi instance =
      KazumiRemoteApi._(BrowserCastServer.instance);

  final BrowserCastServer server;
  final VideoSourceResolverPool _pool = VideoSourceResolverPool();
  final Map<int, BangumiItem> _bangumiCache = {};

  /// 电视解码失败过的规则：之后该规则的集都直接转码。
  final Set<String> _transcodePlugins = {};
  _RemoteSession? _session;
  int _lastSavedProgress = -1;

  PluginsController get _plugins => inject<PluginsController>();
  HistoryController get _history => inject<HistoryController>();

  /// 把接口挂到服务器上并启动；可重复调用。
  Future<void> ensureStarted() async {
    server.apiHandler = handle;
    await server.start();
  }

  /// 桌面端直接投屏（不经过本接口）时调用，避免页面显示过期的剧集信息。
  void clearSession() {
    _session = null;
    unawaited(TranscodeService.instance.stop());
  }

  Future<bool> handle(HttpRequest request) async {
    final path = request.uri.path;
    final q = request.uri.queryParameters;
    try {
      switch (path) {
        case '/api/plugins':
          _json(request, [
            for (final p in _plugins.pluginList)
              {'name': p.name, 'version': p.version, 'baseURL': p.baseUrl},
          ]);
        case '/api/bangumi/search':
          final keyword = (q['q'] ?? '').trim();
          if (keyword.isEmpty) {
            _json(request, <Object>[]);
            break;
          }
          final page = await BangumiApi.bangumiSearch(keyword);
          _json(request, [
            for (final item in page?.items ?? <BangumiItem>[]) _bangumi(item)
          ]);
        case '/api/bangumi/trends':
          final list = await BangumiApi.getBangumiTrendsList(limit: 30);
          _json(request, [for (final item in list) _bangumi(item)]);
        case '/api/bangumi/calendar':
          final calendar = await BangumiApi.getCalendar();
          _json(request, [
            for (final day in calendar) [for (final item in day) _bangumi(item)]
          ]);
        case '/api/bangumi':
          final item = await _bangumiById(int.tryParse(q['id'] ?? '') ?? 0);
          if (item == null) {
            _error(request, HttpStatus.notFound, '未找到番剧');
          } else {
            _json(request, _bangumi(item));
          }
        case '/api/sources':
          await _sources(request, q);
        case '/api/roads':
          final plugin = _pluginByName(q['plugin'] ?? '');
          final src = q['src'] ?? '';
          if (plugin == null || src.isEmpty) {
            _error(request, HttpStatus.badRequest, '缺少 plugin 或 src');
            break;
          }
          final roads = await _roads(plugin, src);
          _json(request, _roadsJson(roads));
        case '/api/play':
          await _play(request, await _body(request));
        case '/api/next':
          await _next(request);
        case '/api/retranscode':
          await _retranscode(request);
        case '/api/cmd':
          final body = await _body(request);
          final action = body['action']?.toString() ?? '';
          if (action.isEmpty) {
            _error(request, HttpStatus.badRequest, '缺少 action');
            break;
          }
          var value = body['value'] as num?;
          // 手机侧的绝对定位按真实进度给，转码时要换算回电视时间轴。
          if (action == 'seekTo' && value != null) {
            value = value - (_session?.offset ?? 0);
            if (value < 0) value = 0;
          }
          server.sendCommand(action, value: value);
          _json(request, {'ok': true});
        case '/api/stop':
          server.stopCasting();
          _session = null;
          await TranscodeService.instance.stop();
          _json(request, {'ok': true});
        case '/api/history':
          _json(request, _historyJson());
        case '/api/collect':
          final type = int.tryParse(q['type'] ?? '') ?? 1;
          final items = GStorage.collectibles.values
              .where((c) => c.type == type)
              .toList()
            ..sort((a, b) => b.time.compareTo(a.time));
          _json(request, [
            for (final c in items) {'type': c.type, 'bangumi': _bangumi(c.bangumiItem)}
          ]);
        case '/api/state':
          _json(request, _stateJson());
        default:
          return false;
      }
    } on _ApiException catch (e) {
      _error(request, e.status, e.message);
    } catch (e, s) {
      KazumiLogger().e('RemoteApi: $path failed', error: e, stackTrace: s);
      _error(request, HttpStatus.internalServerError, e.toString());
    }
    return true;
  }

  // ---- search / sources / roads ----

  Future<void> _sources(HttpRequest request, Map<String, String> q) async {
    final id = int.tryParse(q['id'] ?? '') ?? 0;
    var keyword = (q['q'] ?? '').trim();
    if (keyword.isEmpty && id > 0) {
      final item = await _bangumiById(id);
      keyword = item == null
          ? ''
          : (item.nameCn.isNotEmpty ? item.nameCn : item.name);
    }
    if (keyword.isEmpty) {
      throw const _ApiException(HttpStatus.badRequest, '缺少关键字');
    }
    final plugins = List<Plugin>.of(_plugins.pluginList);
    final results = await Future.wait(plugins.map((plugin) async {
      try {
        final response = await plugin
            .queryBangumi(keyword, shouldRethrow: true)
            .timeout(const Duration(seconds: 20));
        return {
          'plugin': plugin.name,
          'status': 'ok',
          'items': [
            for (final item in response.data) {'name': item.name, 'src': item.src}
          ],
        };
      } on NoResultException {
        return {'plugin': plugin.name, 'status': 'empty', 'items': <Object>[]};
      } on CaptchaRequiredException {
        return {'plugin': plugin.name, 'status': 'captcha', 'items': <Object>[]};
      } on TimeoutException {
        return {'plugin': plugin.name, 'status': 'timeout', 'items': <Object>[]};
      } catch (e) {
        KazumiLogger().w('RemoteApi: ${plugin.name} search failed', error: e);
        return {'plugin': plugin.name, 'status': 'error', 'items': <Object>[]};
      }
    }));
    _json(request, {'keyword': keyword, 'sources': results});
  }

  Future<List<Road>> _roads(Plugin plugin, String src) async {
    final cached = _session;
    if (cached != null && cached.plugin.name == plugin.name && cached.src == src) {
      return cached.roads;
    }
    final roads = await plugin.queryChapterRoads(src);
    if (roads.isEmpty) {
      throw const _ApiException(HttpStatus.notFound, '没有获取到播放列表');
    }
    return roads;
  }

  List<Map<String, Object>> _roadsJson(List<Road> roads) => [
        for (final road in roads)
          {
            'name': road.name,
            'episodes': [
              for (var i = 0; i < road.data.length; i++)
                {
                  'index': i + 1,
                  'title': i < road.identifier.length ? road.identifier[i] : '${i + 1}',
                  'pageUrl': road.data[i],
                }
            ],
          }
      ];

  // ---- play ----

  Future<void> _play(HttpRequest request, Map<String, dynamic> body) async {
    final id = (body['id'] as num?)?.toInt() ?? 0;
    final plugin = _pluginByName(body['plugin']?.toString() ?? '');
    final src = body['src']?.toString() ?? '';
    final road = (body['road'] as num?)?.toInt() ?? 0;
    final episode = (body['episode'] as num?)?.toInt() ?? 1;
    if (plugin == null || src.isEmpty) {
      throw const _ApiException(HttpStatus.badRequest, '缺少 plugin 或 src');
    }
    final item = await _bangumiById(id);
    if (item == null) {
      throw const _ApiException(HttpStatus.badRequest, '未找到番剧信息');
    }
    final roads = await _roads(plugin, src);
    if (road < 0 || road >= roads.length) {
      throw const _ApiException(HttpStatus.badRequest, '线路不存在');
    }
    final roadData = roads[road];
    if (episode < 1 || episode > roadData.data.length) {
      throw const _ApiException(HttpStatus.badRequest, '集数不存在');
    }
    final pageUrl = roadData.data[episode - 1];
    final episodeTitle =
        episode - 1 < roadData.identifier.length ? roadData.identifier[episode - 1] : '第$episode话';
    final explicitStart = (body['start'] as num?)?.toInt();
    final start = explicitStart ??
        _history.findProgress(item, plugin.name, episode)?.progress.inSeconds ??
        0;
    final transcode =
        body['transcode'] == true || _transcodePlugins.contains(plugin.name);

    final lease = _pool.tryAcquire('remote');
    if (lease == null) {
      throw const _ApiException(HttpStatus.conflict, '正在解析其他视频，请稍候');
    }
    final urlItem = normalizeEpisodeUrl(plugin.baseUrl, pageUrl);
    KazumiLogger().i('RemoteApi: resolving ${plugin.name} $episodeTitle $urlItem');
    final VideoSource source;
    try {
      source = await lease.resolve(
        urlItem,
        useLegacyParser: plugin.useLegacyParser,
        timeout: const Duration(seconds: 30),
      );
    } catch (e) {
      KazumiLogger().w('RemoteApi: resolve failed', error: e);
      throw _ApiException(HttpStatus.badGateway, '视频解析失败: $e');
    } finally {
      _pool.release(lease);
    }

    final identity = PlaybackHistoryIdentity.online(
      bangumiItem: item,
      pluginName: plugin.name,
      episodeNumber: episode,
      episodeTitle: episodeTitle,
      road: road,
      onlineBangumiSrc: src,
      episodePageUrl: pageUrl,
    );
    final displayName = item.nameCn.isNotEmpty ? item.nameCn : item.name;
    final headers = plugin.buildHttpHeaders();
    String? localDir;
    if (transcode) {
      try {
        final t = await TranscodeService.instance.start(
          url: source.url,
          headers: headers,
          startSeconds: start,
        );
        localDir = t.dir.path;
      } catch (e) {
        KazumiLogger().w('RemoteApi: transcode failed', error: e);
        throw _ApiException(HttpStatus.badGateway, '$e');
      }
    } else {
      await TranscodeService.instance.stop();
    }
    // 转码时 ffmpeg 已从 start 处开始，电视时间轴从 0 算，保存历史时补回偏移。
    final offset = transcode ? start : 0;
    server.cast(
      url: source.url,
      headers: headers,
      title: '$displayName  $episodeTitle',
      startSeconds: transcode ? 0 : start,
      isHls: source.format == VideoSourceFormat.hls,
      localDir: localDir,
    );
    _session = _RemoteSession(
      bangumi: item,
      plugin: plugin,
      src: src,
      roads: roads,
      road: road,
      episode: episode,
      episodeTitle: episodeTitle,
      identity: identity,
      transcoded: transcode,
      offset: offset,
    );
    _lastSavedProgress = -1;
    server.onProgress =
        (seconds) => _saveProgress(identity, seconds + offset);
    unawaited(_history.updateHistory(identity, Duration(seconds: start)));
    _json(request, {
      'ok': true,
      'title': episodeTitle,
      'start': start,
      'transcoded': transcode,
    });
  }

  /// 电视解码失败后由页面（或手机上的按钮）调用：记住该规则需要转码，
  /// 从失败位置重新播放当前集。
  Future<void> _retranscode(HttpRequest request) async {
    final session = _session;
    if (session == null) {
      throw const _ApiException(HttpStatus.conflict, '当前没有在播放');
    }
    if (await FfmpegLocator.find() == null) {
      throw const _ApiException(
          HttpStatus.notImplemented, '未找到 ffmpeg，无法转码：请把 ffmpeg.exe 放到 Kazumi 程序目录');
    }
    _transcodePlugins.add(session.plugin.name);
    final resume = server.lastPositionSeconds + session.offset;
    await _play(request, {
      'id': session.bangumi.id,
      'plugin': session.plugin.name,
      'src': session.src,
      'road': session.road,
      'episode': session.episode,
      'start': resume > 5 ? resume : 0,
      'transcode': true,
    });
  }

  Future<void> _next(HttpRequest request) async {
    final session = _session;
    if (session == null) {
      throw const _ApiException(HttpStatus.conflict, '当前没有在播放');
    }
    if (session.episode >= session.roads[session.road].data.length) {
      _json(request, {'ok': false, 'error': '已经是最后一集'});
      return;
    }
    await _play(request, {
      'id': session.bangumi.id,
      'plugin': session.plugin.name,
      'src': session.src,
      'road': session.road,
      'episode': session.episode + 1,
      'start': 0,
    });
  }

  void _saveProgress(PlaybackHistoryIdentity identity, int seconds) {
    if ((seconds - _lastSavedProgress).abs() < 5) {
      return;
    }
    _lastSavedProgress = seconds;
    unawaited(_history.updateHistory(identity, Duration(seconds: seconds)));
  }

  // ---- lists ----

  List<Map<String, Object?>> _historyJson() {
    final histories = GStorage.histories.values
        .where((h) => HistoryEntryKind.normalize(h.entryKind) == HistoryEntryKind.online)
        .toList()
      ..sort((a, b) => b.lastWatchTime.compareTo(a.lastWatchTime));
    return [
      for (final h in histories.take(60))
        {
          'bangumi': _bangumi(h.bangumiItem),
          'plugin': h.adapterName,
          'src': h.lastSrc,
          'episode': h.lastWatchEpisode,
          'road': h.progresses[h.lastWatchEpisode]?.road ?? 0,
          'episodeTitle': h.lastWatchEpisodeName,
          'progress': h.progresses[h.lastWatchEpisode]?.progress.inSeconds ?? 0,
          'updatedAt': h.lastWatchTime.millisecondsSinceEpoch,
        }
    ];
  }

  Map<String, Object?> _stateJson() {
    final session = _session;
    return {
      'running': true,
      'status': server.status.value,
      'position': server.lastPositionSeconds + (session?.offset ?? 0),
      'duration': server.lastDurationSeconds + (session?.offset ?? 0),
      'playing': server.playing,
      'casting': server.session != null,
      'transcoded': session?.transcoded ?? false,
      'encoder': TranscodeService.instance.encoder,
      'now': session == null
          ? null
          : {
              'bangumi': _bangumi(session.bangumi),
              'plugin': session.plugin.name,
              'src': session.src,
              'road': session.road,
              'episode': session.episode,
              'episodeTitle': session.episodeTitle,
              'episodeCount': session.roads[session.road].data.length,
            },
    };
  }

  // ---- helpers ----

  Plugin? _pluginByName(String name) {
    for (final plugin in _plugins.pluginList) {
      if (plugin.name == name) {
        return plugin;
      }
    }
    return null;
  }

  Future<BangumiItem?> _bangumiById(int id) async {
    if (id <= 0) {
      return null;
    }
    final cached = _bangumiCache[id];
    if (cached != null) {
      return cached;
    }
    for (final c in GStorage.collectibles.values) {
      if (c.bangumiItem.id == id) {
        return _bangumiCache[id] = c.bangumiItem;
      }
    }
    for (final h in GStorage.histories.values) {
      if (h.bangumiItem.id == id) {
        return _bangumiCache[id] = h.bangumiItem;
      }
    }
    final fetched = await BangumiApi.getBangumiInfoByID(id);
    if (fetched != null) {
      _bangumiCache[id] = fetched;
    }
    return fetched;
  }

  Map<String, Object?> _bangumi(BangumiItem b) {
    final summary = b.summary.replaceAll(RegExp(r'\s+'), ' ').trim();
    return {
      'id': b.id,
      'name': b.name,
      'nameCn': b.nameCn,
      'image': b.images['large'] ?? b.images['common'] ?? b.images['medium'] ?? '',
      'airDate': b.airDate,
      'airWeekday': b.airWeekday,
      'score': b.ratingScore,
      'summary': summary.length > 160 ? '${summary.substring(0, 160)}…' : summary,
    };
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    final text = await utf8.decodeStream(request);
    if (text.trim().isEmpty) {
      return {};
    }
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : {};
  }

  void _json(HttpRequest request, Object body) {
    final bytes = utf8.encode(jsonEncode(body));
    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
  }

  void _error(HttpRequest request, int status, String message) {
    request.response.statusCode = status;
    _json(request, {'error': message});
  }
}

class _RemoteSession {
  final BangumiItem bangumi;
  final Plugin plugin;
  final String src;
  final List<Road> roads;
  final int road;
  final int episode;
  final String episodeTitle;
  final PlaybackHistoryIdentity identity;
  final bool transcoded;

  /// 转码时电视时间轴相对于真实进度的偏移（秒）。
  final int offset;

  _RemoteSession({
    required this.bangumi,
    required this.plugin,
    required this.src,
    required this.roads,
    required this.road,
    required this.episode,
    required this.episodeTitle,
    required this.identity,
    this.transcoded = false,
    this.offset = 0,
  });
}

class _ApiException implements Exception {
  final int status;
  final String message;
  const _ApiException(this.status, this.message);
}
