import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/browser_cast_server.dart';
import 'package:kazumi/services/remote/remote_api.dart';

/// 浏览器投屏入口：启动本机服务并提示用户在电视浏览器中打开地址。
class BrowserCast {
  /// 启动服务（含远程控制接口），失败时提示；返回是否成功。
  static Future<bool> ensureServer() async {
    try {
      await KazumiRemoteApi.instance.ensureStarted();
      return true;
    } catch (e) {
      KazumiLogger().e('BrowserCast: failed to start server', error: e);
      KazumiDialog.showToast(message: '浏览器投屏启动失败: $e');
      return false;
    }
  }

  Future<void> castVideo({
    required String videoUrl,
    required Map<String, String> headers,
    required String title,
    required int startSeconds,
    bool? isHls,
  }) async {
    if (!await ensureServer()) {
      return;
    }
    final server = BrowserCastServer.instance;
    KazumiRemoteApi.instance.clearSession(); // 同时停止可能在跑的转码
    server.cast(
      url: videoUrl,
      headers: headers,
      title: title,
      startSeconds: startSeconds,
      isHls: isHls,
    );
    await showAddressDialog();
  }

  /// 显示访问地址与电视状态；[server] 已启动时才有意义。
  static Future<void> showAddressDialog() async {
    final server = BrowserCastServer.instance;
    final urls = await server.addresses();
    if (urls.isEmpty) {
      KazumiDialog.showToast(message: '未找到可用的局域网地址');
      return;
    }
    await KazumiDialog.show(builder: (BuildContext context) {
      final outline = Theme.of(context).colorScheme.outline;
      return AlertDialog(
        title: const Text('浏览器投屏'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('在电视或手机浏览器中打开：'),
              const SizedBox(height: 8),
              SelectableText(
                urls.first,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (urls.length > 1) ...[
                const SizedBox(height: 8),
                Text('其他网卡地址：${urls.skip(1).join('  ')}',
                    style: TextStyle(color: outline, fontSize: 12)),
              ],
              const SizedBox(height: 12),
              Text(
                '电视打开后会自动播放当前视频；页面里也可以直接搜索、选源、选集，'
                '手机打开同一地址则作为遥控器使用。'
                '${server.port == 80 ? '' : '\n注意：当前使用 ${server.port} 端口，部分电视浏览器只允许 80 端口。'}',
                style: TextStyle(color: outline, fontSize: 12),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: server.status,
                builder: (_, value, _) => Text('电视状态：$value'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: urls.first));
              KazumiDialog.showToast(message: '地址已复制');
            },
            child: Text('复制地址', style: TextStyle(color: outline)),
          ),
          TextButton(
            onPressed: () {
              server.stopCasting();
              KazumiDialog.dismiss();
            },
            child: Text('停止投屏', style: TextStyle(color: outline)),
          ),
          TextButton(
            onPressed: KazumiDialog.dismiss,
            child: const Text('关闭'),
          ),
        ],
      );
    });
  }
}
