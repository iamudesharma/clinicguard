import 'package:flutter_test/flutter_test.dart';

import 'package:poc_client/main.dart';

void main() {
  testWidgets('POC client renders call screen', (tester) async {
    await tester.pumpWidget(const PocClientApp());
    expect(find.text('voicepipe POC — client'), findsOneWidget);
    expect(find.text('Start call'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);
  });
}
