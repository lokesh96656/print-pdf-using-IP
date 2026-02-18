import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doc_print/main.dart';

void main() {
  testWidgets('App loads and shows PDF Printer', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('PDF Printer'), findsOneWidget);
  });
}
