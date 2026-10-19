import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/widgets.dart';
import '../../domain/catalog.dart';
import '../../domain/period.dart';
import '../../domain/report.dart';
import 'csv_export.dart';

/// "Export data (CSV)": the period's sent reports as a spreadsheet file.
class CsvExportButton extends StatefulWidget {
  const CsvExportButton({
    super.key,
    required this.period,
    required this.catalog,
    required this.reports,
  });

  final Period period;
  final Catalog catalog;
  final List<Report> reports;

  @override
  State<CsvExportButton> createState() => _CsvExportButtonState();
}

class _CsvExportButtonState extends State<CsvExportButton> {
  bool _busy = false;

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = csvBytes(
        buildReportsCsv(
          period: widget.period,
          catalog: widget.catalog,
          reports: widget.reports,
        ),
      );
      final name = csvFileBase(widget.period);
      if (kIsWeb) {
        await FileSaver.instance.saveFile(
          name: name,
          bytes: bytes,
          fileExtension: 'csv',
          mimeType: MimeType.csv,
        );
      } else {
        await FileSaver.instance.saveAs(
          name: name,
          bytes: bytes,
          fileExtension: 'csv',
          mimeType: MimeType.csv,
        );
      }
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not export the data. $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final any = widget.reports.any((r) => r.isSubmitted);
    return Tooltip(
      message: any
          ? 'One row per count and month, plus targets and notes'
          : 'Nothing to export yet',
      child: SmallButton(
        label: 'Export data (CSV)',
        onPressed: any && !_busy ? () => _export() : null,
      ),
    );
  }
}
