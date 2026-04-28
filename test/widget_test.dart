import 'package:flutter_test/flutter_test.dart';

import 'package:lightwhisper/app.dart';

void main() {
  testWidgets('App boots to home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const LightWhisperApp());
    expect(find.text('双击拍一拍 | 摇动进入数字模式'), findsOneWidget);
  });
}
