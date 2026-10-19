import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/widgets.dart';
import '../form/form_controller.dart';
import '../form/form_screen.dart';
import '../shell/top_bar.dart';
import 'live_preview.dart';

/// Width from which the preview sits beside the form.
const wideBreakpoint = 1100.0;

/// Width of the form column on wide screens.
const formColumnWidth = 656.0;

/// What an employee sees: their own report form and nothing else. A manager
/// reaches the same form from the dashboard to fill in or fix a report.
class EmployeeScreen extends ConsumerWidget {
  const EmployeeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider);
    final isManager = ref.watch(isControllerProvider);
    final hasPerson = ref.watch(
      formControllerProvider.select((f) => f.hasPerson),
    );
    return Scaffold(
      appBar: const TopBar(screen: Screen.employee),
      body: catalog.when(
        data: (_) => LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= wideBreakpoint;
            final form = Column(
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
                if (!wide && hasPerson) ...[
                  const CollapsiblePreview(),
                  const SizedBox(height: 20),
                ],
                const FormCards(),
              ],
            );
            final bottom = 64 + MediaQuery.paddingOf(context).bottom;
            if (!wide) {
              return Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      isManager ? 12 : 28,
                      16,
                      bottom,
                    ),
                    child: form,
                  ),
                ),
              );
            }
            // The form scrolls on the left, the slides stay in view on the right.
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1360),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: formColumnWidth,
                        child: SingleChildScrollView(
                          padding: EdgeInsets.fromLTRB(
                            0,
                            isManager ? 12 : 28,
                            0,
                            bottom,
                          ),
                          child: form,
                        ),
                      ),
                      const SizedBox(width: 32),
                      const Expanded(child: PreviewColumn()),
                    ],
                  ),
                ),
              ),
            );
          },
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
