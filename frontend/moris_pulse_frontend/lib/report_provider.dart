import 'package:flutter/material.dart';
import 'report_service.dart';

class ReportsProvider extends ChangeNotifier {
  final ReportsService _service = ReportsService();

  List<DistrictReport> reports = [];
  bool isLoading = false;
  String? error;

  Future<void> loadReports() async {
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      reports = await _service.fetchAllReports();
    } catch (e) {
      error = 'Could not load reports. Pull down to retry.';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }
}
