import 'dart:async'; // StreamSubscription / Completer / Future 工具
import 'dart:convert'; // utf8 / jsonEncode / jsonDecode
import 'dart:typed_data'; // Uint8List / ByteData / ByteBuffer

import 'package:flutter/foundation.dart'; // debugPrint / kDebugMode
import 'package:flutter_dotenv/flutter_dotenv.dart'; // .env 配置读取
import 'package:permission_handler/permission_handler.dart'; // 麦克风权限请求
import 'package:record/record.dart'; // 录音 PCM 流
import 'package:uuid/uuid.dart'; // 请求 id 生成
import 'package:web_socket_channel/io.dart'; // WebSocket 客户端
import 'package:web_socket_channel/status.dart' as status; // 关闭码常量

/// 低层 ASR 流式服务：
/// - 负责录音 PCM 采集；
/// - 负责 WebSocket 协议收发；
/// - 负责把增量结果聚合为最终文本。
class AsrService {
  AsrService._internal(); // 私有构造，约束单例

  static final AsrService instance = AsrService._internal(); // 全局单例

  static const String _wsUrl =
      'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async'; // 服务端 ws 地址
  static const List<int> _fullClientHeader = [0x11, 0x10, 0x10, 0x00]; // 首包头（带配置）
  static const List<int> _audioOnlyHeader = [0x11, 0x20, 0x00, 0x00]; // 音频包头（中间帧）
  static const List<int> _lastAudioHeader = [0x11, 0x22, 0x00, 0x00]; // 末包头（结束帧）
  static const Duration _stopGracePeriod = Duration(milliseconds: 800); // stop 后等待尾帧宽限期
  static const Uuid _uuid = Uuid(); // UUID 生成器

  final AudioRecorder _recorder = AudioRecorder(); // 录音器实例

  IOWebSocketChannel? _channel; // 当前 ws 连接
  StreamSubscription<dynamic>? _socketSubscription; // ws 消息订阅
  StreamSubscription<Uint8List>? _audioSubscription; // 录音流订阅
  Completer<void>? _stopWaiter; // 等待服务端最后确认的 completer

  bool _isRecording = false; // 是否处于录音中
  bool _isStopping = false; // 是否处于停止阶段
  String _committedText = ''; // 已确认文本累计
  String _liveText = ''; // 暂态文本
  String _finalText = ''; // 服务端给的最终文本
  String _lastCallbackText = ''; // 去重：上次回调文本
  bool? _lastCallbackDefinite; // 去重：上次回调 definite 标记
  String _lastCommittedUtterance = ''; // 去重：上次已提交句段
  void Function(String text, bool isDefinite)? _onResult; // 对上层的回调

  bool get isRecording => _isRecording; // 对外暴露录音状态

  /// 启动录音并建立 ASR 会话。
  Future<void> startRecording(
    void Function(String text, bool isDefinite) onResult, // 结果回调
  ) async {
    debugPrint('[ASR] startRecording invoked'); // 启动日志
    await _disposeSession(); // 保险起见先清理历史会话
    _resetState(); // 清空状态缓存
    _onResult = onResult; // 注册回调

    final apiKey = _requiredEnv('ASR_API_KEY'); // 读取 key
    final resourceId = _requiredEnv('ASR_API_RESOURCE_ID'); // 读取资源 id
    debugPrint(
      '[ASR] env ready apiKeyLen=${apiKey.length} resourceId=$resourceId', // 日志仅打印长度，避免泄漏 key
    );

    final permission = await Permission.microphone.request(); // 请求麦克风权限
    if (!permission.isGranted) {
      throw Exception('麦克风权限未授予，请在设置中开启'); // 权限失败直接抛给上层
    }

    final requestId = _uuid.v4(); // 生成本次请求 id
    debugPrint('[ASR] websocket connecting url=$_wsUrl requestId=$requestId'); // 连接日志
    final channel = IOWebSocketChannel.connect(
      Uri.parse(_wsUrl), // ws url
      headers: {
        'X-Api-Key': apiKey, // 鉴权 key
        'X-Api-Resource-Id': resourceId, // 资源 id
        'X-Api-Request-Id': requestId, // 请求 id
        'X-Api-Sequence': '-1', // 协议要求的序列值
      },
    );

    _channel = channel; // 保存连接
    _socketSubscription = channel.stream.listen(
      _handleSocketMessage, // 消息处理
      onError: _handleSocketError, // 错误处理
      onDone: _handleSocketDone, // 关闭处理
      cancelOnError: false, // 出错后仍让流程走完收尾
    );

    debugPrint('[ASR] websocket connected, sending full client request'); // 连接成功日志
    _sendPacket(
      _fullClientHeader, // 首包头
      utf8.encode(
        jsonEncode({
          'user': {'uid': _uuid.v4()}, // 用户 id
          'audio': {
            'format': 'pcm', // 音频编码
            'rate': 16000, // 采样率
            'bits': 16, // 位深
            'channel': 1, // 单声道
            'language': 'zh-CN', // 语言
          },
          'request': {
            'model_name': 'bigmodel', // 模型名
            'enable_ddc': true, // 服务端特性开关
          },
        }),
      ),
    );

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits, // 输出 PCM16
        sampleRate: 16000, // 16k 采样
        numChannels: 1, // 单声道
      ),
    );

    debugPrint('[ASR] recorder stream started sampleRate=16000 channels=1 bits=16'); // 录音启动日志
    var audioPacketCount = 0; // 统计发送包数量
    _audioSubscription = stream.listen(
      (chunk) {
        if (!_isRecording || _isStopping || chunk.isEmpty) {
          return; // 非录音态/停止态/空包时不发送
        }
        _sendPacket(_audioOnlyHeader, chunk); // 发送音频中间包
        audioPacketCount += 1; // 计数+1
        if (audioPacketCount <= 3 || audioPacketCount % 20 == 0) {
          debugPrint(
            '[ASR] audio packet #$audioPacketCount bytes=${chunk.length}', // 限频日志
          );
        }
      },
      onError: _handleAudioError, // 音频流错误处理
      cancelOnError: true, // 音频流错误后自动取消
    );

    _isRecording = true; // 标记录音已开始
    debugPrint('[ASR] started recording stream'); // 完成日志
  }

  /// 停止录音并返回最终文本。
  Future<String> stopRecording() async {
    debugPrint('[ASR] stopRecording invoked isRecording=$_isRecording isStopping=$_isStopping'); // 停止日志
    if (!_isRecording && !_isStopping) {
      return _resolvedFinalText(); // 已不在录音时直接返回当前最优文本
    }

    _isStopping = true; // 进入停止阶段
    _stopWaiter ??= Completer<void>(); // 初始化 stop waiter

    await _audioSubscription?.cancel(); // 停止音频流上行
    _audioSubscription = null; // 清空引用

    if (await _recorder.isRecording()) {
      await _recorder.stop(); // 停止本地录音器
    }

    try {
      _sendPacket(_lastAudioHeader, const <int>[]); // 发送末包，通知服务端结束
      debugPrint('[ASR] sent last audio packet'); // 日志
    } catch (e) {
      debugPrint('[ASR] send last audio failed: $e'); // 末包发送失败日志（不中断）
    }

    try {
      await _stopWaiter!.future.timeout(_stopGracePeriod); // 等待服务端最后结果（超时后继续）
    } catch (_) {}

    final finalText = _resolvedFinalText(); // 汇总最终文本
    final source = _finalText.trim().isNotEmpty ? 'result.text' : 'committed+live'; // 记录来源
    debugPrint('[ASR] stop resolved finalText="$finalText" source=$source'); // 日志
    await _disposeSession(); // 清理会话资源
    return finalText; // 返回最终文本
  }

  /// 取消录音会话（通常用于页面销毁）。
  Future<void> cancelRecording() async {
    await _disposeSession(); // 直接清理
  }

  /// 读取必填环境变量，缺失则抛异常。
  String _requiredEnv(String key) {
    final value = dotenv.env[key]?.trim() ?? ''; // 读取并清理
    if (value.isEmpty) {
      throw Exception('Missing $key in .env'); // 缺失时抛错
    }
    return value; // 返回值
  }

  /// 处理 ws 消息帧。
  void _handleSocketMessage(dynamic message) {
    try {
      final bytes = _asBytes(message); // 统一转换为 Uint8List
      if (bytes == null || bytes.length < 12) {
        return; // 协议头不完整时丢弃
      }

      final payloadBytes = bytes.sublist(12); // 跳过 12 字节头部
      if (payloadBytes.isEmpty) {
        return; // 空负载直接忽略
      }
      if (kDebugMode) {
        final seq = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.big); // 读取序列号
        if (seq <= 2 || seq % 10 == 0) {
          debugPrint('[ASR] recv frame seq=$seq payloadBytes=${payloadBytes.length}'); // 限频日志
        }
      }

      final jsonString = utf8.decode(payloadBytes, allowMalformed: true).trim(); // 负载转字符串
      if (jsonString.isEmpty) {
        return; // 空字符串直接忽略
      }

      final decoded = jsonDecode(jsonString); // JSON 解析
      if (decoded is! Map) {
        return; // 非对象结构忽略
      }

      final map = Map<String, dynamic>.from(decoded); // 转强类型 map
      _consumeResult(map); // 消费识别结果
    } catch (e) {
      debugPrint('[ASR] parse frame failed: $e'); // 解析失败日志
    }
  }

  /// 把不同消息类型统一转换成 Uint8List。
  Uint8List? _asBytes(dynamic message) {
    if (message is Uint8List) {
      return message; // 已是目标类型
    }
    if (message is List<int>) {
      return Uint8List.fromList(message); // List<int> 转换
    }
    if (message is ByteBuffer) {
      return message.asUint8List(); // ByteBuffer 转换
    }
    return null; // 其他类型不支持
  }

  /// 消费服务端 result 字段并更新文本状态。
  void _consumeResult(Map<String, dynamic> payload) {
    final resultValue = payload['result']; // 取 result
    if (resultValue is! Map) {
      return; // 非对象则忽略
    }
    final result = Map<String, dynamic>.from(resultValue); // 强类型 map

    final fullText = (result['text'] as String?)?.trim() ?? ''; // 服务端最终全文
    if (fullText.isNotEmpty) {
      _finalText = fullText; // 有值则覆盖最终文本
    }

    final utterances = result['utterances']; // 增量句段列表
    if (utterances is! List) {
      return; // 不是列表则结束
    }

    for (final item in utterances) {
      if (item is! Map) {
        continue; // 非对象项跳过
      }
      final utterance = Map<String, dynamic>.from(item); // 强类型 map
      final text = (utterance['text'] as String?)?.trim() ?? ''; // 句段文本
      if (text.isEmpty) {
        continue; // 空句段跳过
      }
      final definite = utterance['definite'] == true; // 是否已确认
      if (definite) {
        _liveText = ''; // 确认后清空暂态文本
        if (_lastCommittedUtterance != text) {
          _lastCommittedUtterance = text; // 更新去重基线
          _committedText = _finalTextIfAvailableOrAppend(text); // 合并到 committed
        }
      } else {
        _liveText = text; // 暂态文本更新
      }
      _emitResult(text, definite); // 回调给上层
      if (kDebugMode) {
        debugPrint('[ASR] utterance definite=$definite text="$text"'); // 调试日志
      }
    }
  }

  /// 计算 committed 文本：优先服务端 finalText，否则做追加去重。
  String _finalTextIfAvailableOrAppend(String utterance) {
    final base = _finalText.trim(); // 服务端最终全文
    if (base.isNotEmpty) {
      return base; // 有最终全文直接用
    }
    final previous = _committedText.trim(); // 旧 committed
    if (previous.isEmpty) {
      return utterance; // 首次提交
    }
    if (previous.endsWith(utterance)) {
      return previous; // 已包含则不重复追加
    }
    return '$previous$utterance'; // 追加新句段
  }

  /// 去重回调并在 definite 结果时释放 stop 等待。
  void _emitResult(String text, bool isDefinite) {
    if (_lastCallbackText == text && _lastCallbackDefinite == isDefinite) {
      return; // 去重：相同文本+相同状态不重复回调
    }
    _lastCallbackText = text; // 更新去重文本
    _lastCallbackDefinite = isDefinite; // 更新去重状态
    _onResult?.call(text, isDefinite); // 回调上层
    if (isDefinite && !_stopWaiterIsCompleted()) {
      _stopWaiter?.complete(); // 收到确定结果后尽快结束 stop 等待
    }
  }

  /// stop waiter 是否已完成。
  bool _stopWaiterIsCompleted() => _stopWaiter?.isCompleted ?? true;

  /// ws 错误处理。
  void _handleSocketError(Object error, [StackTrace? stackTrace]) {
    debugPrint('[ASR] websocket error: $error'); // 日志
    if (!_stopWaiterIsCompleted()) {
      _stopWaiter?.complete(); // 避免 stop 永远等待
    }
  }

  /// ws 正常关闭处理。
  void _handleSocketDone() {
    debugPrint('[ASR] websocket closed'); // 日志
    if (!_stopWaiterIsCompleted()) {
      _stopWaiter?.complete(); // 避免 stop 等待悬挂
    }
  }

  /// 音频流错误处理。
  void _handleAudioError(Object error, [StackTrace? stackTrace]) {
    debugPrint('[ASR] audio stream error: $error'); // 日志
    if (!_stopWaiterIsCompleted()) {
      _stopWaiter?.complete(); // 出错时也释放等待
    }
  }

  /// 发送协议包。
  void _sendPacket(List<int> header, List<int> payload) {
    final channel = _channel; // 当前连接
    if (channel == null) {
      throw StateError('ASR channel not connected'); // 无连接时抛错
    }
    channel.sink.add(_packData(header, payload)); // 打包并发送
  }

  /// 打包：header + payloadLength(4 bytes big-endian) + payload。
  Uint8List _packData(List<int> header, List<int> payload) {
    final bd = ByteData(4); // 4 字节长度区
    bd.setUint32(0, payload.length, Endian.big); // 写入负载长度
    final sizeBytes = bd.buffer.asUint8List(); // 转字节数组
    return Uint8List.fromList([...header, ...sizeBytes, ...payload]); // 拼接完整包
  }

  /// 计算最优最终文本：优先 finalText，否则 committed+live。
  String _resolvedFinalText() {
    final direct = _finalText.trim(); // finalText
    if (direct.isNotEmpty) {
      return direct; // 有 finalText 直接返回
    }
    final merged = '${_committedText.trim()}${_liveText.trim()}'.trim(); // 回退拼接
    return merged; // 返回回退结果
  }

  /// 清理会话资源。
  Future<void> _disposeSession() async {
    _isRecording = false; // 关闭录音态
    _isStopping = false; // 关闭停止态

    await _audioSubscription?.cancel(); // 取消音频订阅
    _audioSubscription = null; // 清空引用

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop(); // 停止录音器
      }
    } catch (e) {
      debugPrint('[ASR] recorder stop failed: $e'); // 仅记录
    }

    await _socketSubscription?.cancel(); // 取消 ws 订阅
    _socketSubscription = null; // 清空引用

    try {
      await _channel?.sink.close(status.normalClosure); // 正常关闭 ws
    } catch (e) {
      debugPrint('[ASR] websocket close failed: $e'); // 仅记录
    }
    _channel = null; // 清空连接

    _stopWaiter = null; // 清空 waiter
    _onResult = null; // 清空回调
  }

  /// 重置文本状态缓存。
  void _resetState() {
    _committedText = ''; // 清空 committed
    _liveText = ''; // 清空 live
    _finalText = ''; // 清空 final
    _lastCallbackText = ''; // 清空回调去重基线
    _lastCallbackDefinite = null; // 清空回调去重状态
    _lastCommittedUtterance = ''; // 清空 committed 去重基线
    _stopWaiter = null; // 清空 waiter
    _isStopping = false; // 重置停止态
    _isRecording = false; // 重置录音态
  }
}
