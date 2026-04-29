import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as status;

class AsrService {
  AsrService._internal();

  static final AsrService instance = AsrService._internal();

  static const String _wsUrl =
      'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async';
  static const List<int> _fullClientHeader = [0x11, 0x10, 0x10, 0x00];
  static const List<int> _audioOnlyHeader = [0x11, 0x20, 0x00, 0x00];
  static const List<int> _lastAudioHeader = [0x11, 0x22, 0x00, 0x00];
  static const Duration _stopGracePeriod = Duration(milliseconds: 800);
  static const Uuid _uuid = Uuid();

  final AudioRecorder _recorder = AudioRecorder();

  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSubscription;
  StreamSubscription<Uint8List>? _audioSubscription;
  Completer<void>? _stopWaiter;

  bool _isRecording = false;
  bool _isStopping = false;
  String _committedText = '';
  String _liveText = '';
  String _finalText = '';
  String _lastCallbackText = '';
  bool? _lastCallbackDefinite;
  String _lastCommittedUtterance = '';
  void Function(String text, bool isDefinite)? _onResult;

  bool get isRecording => _isRecording;

  Future<void> startRecording(
    void Function(String text, bool isDefinite) onResult,
  ) async {
    debugPrint('[ASR] startRecording invoked');
    await _disposeSession();
    _resetState();
    _onResult = onResult;

    final apiKey = _requiredEnv('ASR_API_KEY');
    final resourceId = _requiredEnv('ASR_API_RESOURCE_ID');
    debugPrint(
      '[ASR] env ready apiKeyLen=${apiKey.length} resourceId=$resourceId',
    );

    final permission = await Permission.microphone.request();
    if (!permission.isGranted) {
      throw Exception('麦克风权限未授予，请在设置中开启');
    }

    final requestId = _uuid.v4();
    debugPrint('[ASR] websocket connecting url=$_wsUrl requestId=$requestId');
    final channel = IOWebSocketChannel.connect(
      Uri.parse(_wsUrl),
      headers: {
        'X-Api-Key': apiKey,
        'X-Api-Resource-Id': resourceId,
        'X-Api-Request-Id': requestId,
        'X-Api-Sequence': '-1',
      },
    );

    _channel = channel;
    _socketSubscription = channel.stream.listen(
      _handleSocketMessage,
      onError: _handleSocketError,
      onDone: _handleSocketDone,
      cancelOnError: false,
    );

    debugPrint('[ASR] websocket connected, sending full client request');
    _sendPacket(
      _fullClientHeader,
      utf8.encode(
        jsonEncode({
          'user': {'uid': _uuid.v4()},
          'audio': {
            'format': 'pcm',
            'rate': 16000,
            'bits': 16,
            'channel': 1,
            'language': 'zh-CN',
          },
          'request': {
            'model_name': 'bigmodel',
            'enable_ddc': true,
          },
        }),
      ),
    );

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );

    debugPrint('[ASR] recorder stream started sampleRate=16000 channels=1 bits=16');
    var audioPacketCount = 0;
    _audioSubscription = stream.listen(
      (chunk) {
        if (!_isRecording || _isStopping || chunk.isEmpty) {
          return;
        }
        _sendPacket(_audioOnlyHeader, chunk);
        audioPacketCount += 1;
        if (audioPacketCount <= 3 || audioPacketCount % 20 == 0) {
          debugPrint(
            '[ASR] audio packet #$audioPacketCount bytes=${chunk.length}',
          );
        }
      },
      onError: _handleAudioError,
      cancelOnError: true,
    );

    _isRecording = true;
    debugPrint('[ASR] started recording stream');
  }

  Future<String> stopRecording() async {
    debugPrint('[ASR] stopRecording invoked isRecording=$_isRecording isStopping=$_isStopping');
    if (!_isRecording && !_isStopping) {
      return _resolvedFinalText();
    }

    _isStopping = true;
    _stopWaiter ??= Completer<void>();

    await _audioSubscription?.cancel();
    _audioSubscription = null;

    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }

    try {
      _sendPacket(_lastAudioHeader, const <int>[]);
      debugPrint('[ASR] sent last audio packet');
    } catch (e) {
      debugPrint('[ASR] send last audio failed: $e');
    }

    try {
      await _stopWaiter!.future.timeout(_stopGracePeriod);
    } catch (_) {}

    final finalText = _resolvedFinalText();
    final source = _finalText.trim().isNotEmpty ? 'result.text' : 'committed+live';
    debugPrint('[ASR] stop resolved finalText="$finalText" source=$source');
    await _disposeSession();
    return finalText;
  }

  Future<void> cancelRecording() async {
    await _disposeSession();
  }

  String _requiredEnv(String key) {
    final value = dotenv.env[key]?.trim() ?? '';
    if (value.isEmpty) {
      throw Exception('Missing $key in .env');
    }
    return value;
  }

  void _handleSocketMessage(dynamic message) {
    try {
      final bytes = _asBytes(message);
      if (bytes == null || bytes.length < 12) {
        return;
      }

      final payloadBytes = bytes.sublist(12);
      if (payloadBytes.isEmpty) {
        return;
      }
      if (kDebugMode) {
        final seq = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.big);
        if (seq <= 2 || seq % 10 == 0) {
          debugPrint('[ASR] recv frame seq=$seq payloadBytes=${payloadBytes.length}');
        }
      }

      final jsonString = utf8.decode(payloadBytes, allowMalformed: true).trim();
      if (jsonString.isEmpty) {
        return;
      }

      final decoded = jsonDecode(jsonString);
      if (decoded is! Map) {
        return;
      }

      final map = Map<String, dynamic>.from(decoded);
      _consumeResult(map);
    } catch (e) {
      debugPrint('[ASR] parse frame failed: $e');
    }
  }

  Uint8List? _asBytes(dynamic message) {
    if (message is Uint8List) {
      return message;
    }
    if (message is List<int>) {
      return Uint8List.fromList(message);
    }
    if (message is ByteBuffer) {
      return message.asUint8List();
    }
    return null;
  }

  void _consumeResult(Map<String, dynamic> payload) {
    final resultValue = payload['result'];
    if (resultValue is! Map) {
      return;
    }
    final result = Map<String, dynamic>.from(resultValue);

    final fullText = (result['text'] as String?)?.trim() ?? '';
    if (fullText.isNotEmpty) {
      _finalText = fullText;
    }

    final utterances = result['utterances'];
    if (utterances is! List) {
      return;
    }

    for (final item in utterances) {
      if (item is! Map) {
        continue;
      }
      final utterance = Map<String, dynamic>.from(item);
      final text = (utterance['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) {
        continue;
      }
      final definite = utterance['definite'] == true;
      if (definite) {
        _liveText = '';
        if (_lastCommittedUtterance != text) {
          _lastCommittedUtterance = text;
          _committedText = _finalTextIfAvailableOrAppend(text);
        }
      } else {
        _liveText = text;
      }
      _emitResult(text, definite);
      if (kDebugMode) {
        debugPrint('[ASR] utterance definite=$definite text="$text"');
      }
    }
  }

  String _finalTextIfAvailableOrAppend(String utterance) {
    final base = _finalText.trim();
    if (base.isNotEmpty) {
      return base;
    }
    final previous = _committedText.trim();
    if (previous.isEmpty) {
      return utterance;
    }
    if (previous.endsWith(utterance)) {
      return previous;
    }
    return '$previous$utterance';
  }

  void _emitResult(String text, bool isDefinite) {
    if (_lastCallbackText == text && _lastCallbackDefinite == isDefinite) {
      return;
    }
    _lastCallbackText = text;
    _lastCallbackDefinite = isDefinite;
    _onResult?.call(text, isDefinite);
    if (isDefinite && !_stopWaiterIsCompleted()) {
      _stopWaiter?.complete();
    }
  }

  bool _stopWaiterIsCompleted() => _stopWaiter?.isCompleted ?? true;

  void _handleSocketError(Object error, [StackTrace? stackTrace]) {
    debugPrint('[ASR] websocket error: $error');
    if (!_stopWaiterIsCompleted()) {
      _stopWaiter?.complete();
    }
  }

  void _handleSocketDone() {
    debugPrint('[ASR] websocket closed');
    if (!_stopWaiterIsCompleted()) {
      _stopWaiter?.complete();
    }
  }

  void _handleAudioError(Object error, [StackTrace? stackTrace]) {
    debugPrint('[ASR] audio stream error: $error');
    if (!_stopWaiterIsCompleted()) {
      _stopWaiter?.complete();
    }
  }

  void _sendPacket(List<int> header, List<int> payload) {
    final channel = _channel;
    if (channel == null) {
      throw StateError('ASR channel not connected');
    }
    channel.sink.add(_packData(header, payload));
  }

  Uint8List _packData(List<int> header, List<int> payload) {
    final bd = ByteData(4);
    bd.setUint32(0, payload.length, Endian.big);
    final sizeBytes = bd.buffer.asUint8List();
    return Uint8List.fromList([...header, ...sizeBytes, ...payload]);
  }

  String _resolvedFinalText() {
    final direct = _finalText.trim();
    if (direct.isNotEmpty) {
      return direct;
    }
    final merged = '${_committedText.trim()}${_liveText.trim()}'.trim();
    return merged;
  }

  Future<void> _disposeSession() async {
    _isRecording = false;
    _isStopping = false;

    await _audioSubscription?.cancel();
    _audioSubscription = null;

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (e) {
      debugPrint('[ASR] recorder stop failed: $e');
    }

    await _socketSubscription?.cancel();
    _socketSubscription = null;

    try {
      await _channel?.sink.close(status.normalClosure);
    } catch (e) {
      debugPrint('[ASR] websocket close failed: $e');
    }
    _channel = null;

    _stopWaiter = null;
    _onResult = null;
  }

  void _resetState() {
    _committedText = '';
    _liveText = '';
    _finalText = '';
    _lastCallbackText = '';
    _lastCallbackDefinite = null;
    _lastCommittedUtterance = '';
    _stopWaiter = null;
    _isStopping = false;
    _isRecording = false;
  }
}
