import 'package:shared_preferences/shared_preferences.dart'; // 本地键值存储

import '../models/voice_pack.dart'; // 语音包模型定义

/// 语音包设置服务：
/// - 管理语音包目录；
/// - 读写当前选中语音包；
/// - 保证落库值合法。
class VoiceSettingsService {
  VoiceSettingsService._(); // 私有构造，纯静态工具类

  static const String storageKey = 'selected_tts_voice_id'; // 持久化 key
  static const String defaultVoiceId = 'zh_female_vv_uranus_bigtts'; // 默认语音包 id

  static const List<VoicePack> catalog = [
    VoicePack(id: 'zh_female_vv_uranus_bigtts', label: 'Vivi 2.0'), // 默认女声
    VoicePack(id: 'zh_male_kailangxuezhang_uranus_bigtts', label: '开朗学长2.0'),
    VoicePack(id: 'zh_male_liangsangmengzai_uranus_bigtts', label: '亮嗓萌仔2.0'),
    VoicePack(id: 'zh_female_yingtaowanzi_uranus_bigtts', label: '樱桃丸子2.0'),
    VoicePack(id: 'zh_female_peiqi_uranus_bigtts', label: '佩奇猪2.0'),
    VoicePack(id: 'zh_male_aojiaobazong_uranus_bigtts', label: '傲娇霸总2.0'),
  ];

  static final Set<String> _catalogIds = catalog.map((item) => item.id).toSet(); // 便于 O(1) 校验合法性

  /// 读取当前语音包 id，空值时返回空字符串。
  static Future<String> getSelectedVoiceId() async {
    final prefs = await SharedPreferences.getInstance(); // 获取存储实例
    return prefs.getString(storageKey)?.trim() ?? ''; // 读取并去空白
  }

  /// 保存语音包 id（仅允许目录内 id）。
  static Future<void> setSelectedVoiceId(String id) async {
    final value = id.trim(); // 清理输入
    if (value.isEmpty || !_catalogIds.contains(value)) {
      return; // 空值或非法值直接忽略
    }
    final prefs = await SharedPreferences.getInstance(); // 获取存储实例
    await prefs.setString(storageKey, value); // 持久化写入
  }

  /// 返回合法语音包 id；若当前无效则写回默认值并返回默认值。
  static Future<String> resolveValidVoiceIdOrDefault() async {
    final selected = await getSelectedVoiceId(); // 读取当前值
    if (_catalogIds.contains(selected)) {
      return selected; // 合法则直接返回
    }
    await setSelectedVoiceId(defaultVoiceId); // 不合法则修复存储
    return defaultVoiceId; // 返回默认值
  }

  /// 同步版本的合法性校验（不触发存储 I/O）。
  static String resolveValidVoiceIdOrDefaultSync(String? id) {
    final value = id?.trim() ?? ''; // 规范化输入
    if (_catalogIds.contains(value)) {
      return value; // 合法则返回
    }
    return defaultVoiceId; // 非法则默认
  }
}
