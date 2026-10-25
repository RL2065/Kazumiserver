import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kazumi/services/logging/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 查找 ffmpeg：程序目录 → PATH。结果缓存。
class FfmpegLocator {
  static String? _cached;

  static Future<String?> find() async {
    final cached = _cached;
    if (cached != null && File(cached).existsSync()) {
      return cached;
    }
    final exeName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final beside =
        p.join(File(Platform.resolvedExecutable).parent.path, exeName);
    if (File(beside).existsSync()) {
      return _cached = beside;
    }
    try {
      final result = await Process.run(
          Platform.isWindows ? 'where' : 'which', ['ffmpeg']);
      if (result.exitCode == 0) {
        final line = (result.stdout as String)
            .split('\n')
            .map((l) => l.trim())
            .firstWhere((l) => l.isNotEmpty, orElse: () => '');
        if (line.isNotEmpty && File(line).existsSync()) {
          return _cached = line;
        }
      }
    } catch (_) {}
    return null;
  }
}

class TranscodeSession {
  final Directory dir;
  final Process process;
  final String encoder;
  final List<String> stderrTail = [];
  bool exited = false;
  int? exitCode;

  TranscodeSession(this.dir, this.process, this.encoder);
}

/// 用 ffmpeg 把电视解码不了的流实时转成 H.264 High L4.1 + AAC 48k 的 HLS，
/// 边转边播。同一时间只有一个转码任务。
class TranscodeService {
  TranscodeService._();

  static final TranscodeService instance = TranscodeService._();

  static const List<String> _encoderCandidates = [
    'h264_nvenc',
    'h264_qsv',
    'h264_amf',
    'libx264',
  ];

  String? _encoder;
  TranscodeSession? _current;

  String? get encoder => _encoder;

  TranscodeSession? get current => _current;

  Future<String> detectEncoder(String ffmpeg) async {
    for (final candidate in _encoderCandidates) {
      try {
        final result = await Process.run(ffmpeg, [
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'lavfi',
          '-i',
          'color=c=black:s=256x256:d=0.2',
          '-pix_fmt',
          'yuv420p',
          '-frames:v',
          '3',
          '-c:v',
          candidate,
          '-f',
          'null',
          '-',
        ]).timeout(const Duration(seconds: 20));
        if (result.exitCode == 0) {
          KazumiLogger().i('Transcode: using encoder $candidate');
          return _encoder = candidate;
        }
      } catch (_) {}
    }
    return _encoder = 'libx264';
  }

  List<String> _encoderArgs(String encoder) {
    switch (encoder) {
      case 'h264_nvenc':
        return ['-preset', 'p4', '-rc', 'vbr', '-cq', '23', '-b:v', '0',
          '-maxrate', '12M', '-bufsize', '24M'];
      case 'h264_qsv':
        return ['-preset', 'veryfast', '-global_quality', '23'];
      case 'h264_amf':
        return ['-quality', 'speed', '-rc', 'vbr_peak', '-b:v', '6M'];
      default:
        return ['-preset', 'veryfast', '-crf', '22', '-threads', '0'];
    }
  }

  /// 启动转码，等到播放列表里至少有两个分片再返回。
  Future<TranscodeSession> start({
    required String url,
    required Map<String, String> headers,
    required int startSeconds,
  }) async {
    await stop();
    final ffmpeg = await FfmpegLocator.find();
    if (ffmpeg == null) {
      throw StateError('未找到 ffmpeg，请把 ffmpeg.exe 放到 Kazumi 程序目录');
    }
    final encoder = _encoder ?? await detectEncoder(ffmpeg);
    final root = Directory(
        p.join((await getTemporaryDirectory()).path, 'kazumi_cast'));
    await _cleanRoot(root);
    final dir = Directory(
        p.join(root.path, '${DateTime.now().millisecondsSinceEpoch}'));
    await dir.create(recursive: true);

    final headerLines =
        headers.entries.map((e) => '${e.key}: ${e.value}').join('\r\n');
    final args = <String>[
      '-hide_banner', '-loglevel', 'warning', '-nostdin',
      if (headerLines.isNotEmpty) ...['-headers', '$headerLines\r\n'],
      '-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '5',
      if (startSeconds > 0) ...['-ss', '$startSeconds'],
      '-i', url,
      '-map', '0:v:0', '-map', '0:a:0?',
      '-c:v', encoder, ..._encoderArgs(encoder),
      '-pix_fmt', 'yuv420p', '-profile:v', 'high', '-level', '4.1',
      '-g', '120', '-sc_threshold', '0',
      '-force_key_frames', 'expr:gte(t,n_forced*4)',
      '-c:a', 'aac', '-ar', '48000', '-ac', '2', '-b:a', '160k',
      '-f', 'hls', '-hls_time', '4', '-hls_list_size', '0',
      '-hls_playlist_type', 'event',
      '-hls_flags', 'independent_segments+temp_file',
      '-hls_segment_filename', p.join(dir.path, 'seg%05d.ts'),
      p.join(dir.path, 'index.m3u8'),
    ];
    KazumiLogger().i('Transcode: $encoder $url (start=$startSeconds)');
    final process = await Process.start(ffmpeg, args);
    final session = TranscodeSession(dir, process, encoder);
    _current = session;
    process.stdout.drain<void>();
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      session.stderrTail.add(line);
      if (session.stderrTail.length > 30) {
        session.stderrTail.removeAt(0);
      }
    });
    process.exitCode.then((code) {
      session.exited = true;
      session.exitCode = code;
      if (code != 0 && _current == session) {
        KazumiLogger().w(
            'Transcode: ffmpeg exited with $code: ${session.stderrTail.join(' | ')}');
      } else {
        KazumiLogger().i('Transcode: ffmpeg finished ($code)');
      }
    });

    final playlist = File(p.join(dir.path, 'index.m3u8'));
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (DateTime.now().isBefore(deadline)) {
      if (session.exited && session.exitCode != 0) {
        break;
      }
      if (await playlist.exists()) {
        final text = await playlist.readAsString();
        if ('#EXTINF'.allMatches(text).length >= 2 ||
            text.contains('#EXT-X-ENDLIST')) {
          return session;
        }
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
    final tail = session.stderrTail.isEmpty
        ? '超时'
        : session.stderrTail.skip(session.stderrTail.length - 3).join(' | ');
    await stop();
    throw StateError('ffmpeg 转码失败: $tail');
  }

  Future<void> stop() async {
    final session = _current;
    _current = null;
    if (session == null) {
      return;
    }
    if (!session.exited) {
      session.process.kill();
      try {
        await session.process.exitCode
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    try {
      await session.dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _cleanRoot(Directory root) async {
    if (!await root.exists()) {
      return;
    }
    await for (final entity in root.list()) {
      if (entity is Directory && entity.path != _current?.dir.path) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}
