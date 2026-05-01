import 'package:shared_preferences/shared_preferences.dart';

import '../models/voice_pack.dart';

class VoiceSettingsService {
  VoiceSettingsService._();

  static const String storageKey = 'selected_tts_voice_id';
  static const String defaultVoiceId = 'zh_female_vv_uranus_bigtts';

  static const List<VoicePack> catalog = [
    VoicePack(id: 'zh_female_vv_uranus_bigtts', label: 'Vivi 2.0'),
    VoicePack(id: 'zh_male_kailangxuezhang_uranus_bigtts', label: '开朗学长2.0'),
    VoicePack(id: 'zh_male_liangsangmengzai_uranus_bigtts', label: '亮嗓萌仔2.0'),
    VoicePack(id: 'zh_female_yingtaowanzi_uranus_bigtts', label: '樱桃丸子2.0'),
    VoicePack(id: 'zh_female_peiqi_uranus_bigtts', label: '佩奇猪2.0'),
    VoicePack(id: 'zh_male_aojiaobazong_uranus_bigtts', label: '傲娇霸总2.0'),
  ];

  static final Set<String> _catalogIds = catalog.map((item) => item.id).toSet();

  static Future<String> getSelectedVoiceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(storageKey)?.trim() ?? '';
  }

  static Future<void> setSelectedVoiceId(String id) async {
    final value = id.trim();
    if (value.isEmpty || !_catalogIds.contains(value)) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, value);
  }

  static Future<String> resolveValidVoiceIdOrDefault() async {
    final selected = await getSelectedVoiceId();
    if (_catalogIds.contains(selected)) {
      return selected;
    }
    await setSelectedVoiceId(defaultVoiceId);
    return defaultVoiceId;
  }

  static String resolveValidVoiceIdOrDefaultSync(String? id) {
    final value = id?.trim() ?? '';
    if (_catalogIds.contains(value)) {
      return value;
    }
    return defaultVoiceId;
  }
}
