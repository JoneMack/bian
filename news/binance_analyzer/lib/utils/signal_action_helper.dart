import '../models/strategy_snapshot.dart';

String normalizeSignalActionSymbol(String symbol) {
  final normalized = symbol.trim().toUpperCase();
  if (normalized.endsWith('USDT')) {
    return normalized.substring(0, normalized.length - 4);
  }
  return normalized;
}

String buildSignalActionSignalId({
  required EntryAlertSignal signal,
  required String signalType,
  DateTime? at,
}) {
  final time = at ?? DateTime.now();
  final day = _dayKey(time);
  final symbol = normalizeSignalActionSymbol(signal.symbol);
  final label = signal.timingLabel.trim();
  return '$day|${signalType.toLowerCase()}|$symbol|$label';
}

String buildSignalActionStatusLabel(String actionType) {
  return actionType.trim().toLowerCase() == 'cancel' ? '已取消' : '已确定';
}

String _dayKey(DateTime time) {
  final year = time.year.toString().padLeft(4, '0');
  final month = time.month.toString().padLeft(2, '0');
  final day = time.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}
