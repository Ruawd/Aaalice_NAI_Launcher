import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/presentation/widgets/common/themed_scaffold.dart';

void main() {
  testWidgets('forwards scaffoldKey so an app bar action can open endDrawer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final scaffoldKey = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(
      MaterialApp(
        home: ThemedScaffold(
          scaffoldKey: scaffoldKey,
          appBar: AppBar(
            title: const Text('生成'),
            actions: [
              IconButton(
                key: const ValueKey('generationParametersButton'),
                icon: const Icon(Icons.tune),
                onPressed: () => scaffoldKey.currentState?.openEndDrawer(),
              ),
            ],
          ),
          endDrawer: const Drawer(child: Text('参数设置面板')),
          body: const SizedBox.expand(),
        ),
      ),
    );

    expect(scaffoldKey.currentState, isNotNull);
    await tester.tap(find.byKey(const ValueKey('generationParametersButton')));
    await tester.pumpAndSettle();

    expect(find.text('参数设置面板'), findsOneWidget);
  });
}
