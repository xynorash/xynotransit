import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/widgets.dart';
import '../form/form_screen.dart';
import '../shell/top_bar.dart';

/// What an employee sees: their own report form and nothing else. A manager
/// reaches the same form from the dashboard to fill in or fix a report.
class EmployeeScreen extends ConsumerWidget {
  const EmployeeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider);
    final isManager = ref.watch(isControllerProvider);
    return Scaffold(
      appBar: const TopBar(screen: Screen.employee),
      body: catalog.when(
        data: (_) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                16,
                isManager ? 12 : 28,
                16,
                64 + MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isManager)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextLinkButton(
                        label: '‹ Back to the dashboard',
                        onPressed: () => context.go('/manager/reports'),
                      ),
                    ),
                  const FormHeader(),
                  const SizedBox(height: 20),
                  const FormCards(),
                ],
              ),
            ),
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load the page. Check your connection and reload.',
              style: bodyStyle(context),
            ),
          ),
        ),
      ),
    );
  }
}
