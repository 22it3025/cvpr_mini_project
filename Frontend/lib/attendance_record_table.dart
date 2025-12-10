import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AttendanceTablePage extends StatefulWidget {
  final String subjectCode;
  final String subjectName;

  const AttendanceTablePage({
    Key? key,
    required this.subjectCode,
    required this.subjectName,
  }) : super(key: key);

  @override
  _AttendanceTablePageState createState() => _AttendanceTablePageState();
}

class _AttendanceTablePageState extends State<AttendanceTablePage> {
  List<Map<String, dynamic>> attendanceData = [];
  List<String> dates = [];
  bool isLoading = false;
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _fetchAttendanceData();
  }

  Future<void> _fetchAttendanceData() async {
    final serverUrl = dotenv.env['SERVER_URL'] ?? '';
    setState(() {
      isLoading = true;
      errorMessage = null;
      attendanceData = [];
      dates = [];
    });

    try {
      final response = await http.get(
        Uri.parse('$serverUrl/get_all_attendance?subject_code=${widget.subjectCode}'),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('Server error: ${response.statusCode}');
      }

      final data = json.decode(response.body);

      // -- ENABLE FOR DEBUGGING: prints raw JSON received from server --
      // print('SERVER RESPONSE: ${jsonEncode(data)}');

      if (data['success'] != true) {
        throw Exception(data['message'] ?? 'Failed to fetch attendance');
      }

      // --- Sanitize dates & attendance from server to avoid extra keys ---
      final rawDates = List<String>.from(data['dates'] ?? []);

      // Remove any keys the server might have returned (e.g. 'subject_code', 'created_at')
      final bannedKeys = {'subject_code', 'created_at', 'createdat', 'subjectcode', 'id'};

      // Heuristic: keep entries that look like dates (supports 2025-04-23, 23_04_2025, 23/04/2025 etc.)
      final dateLike = RegExp(r'\d{1,4}[-_/]\d{1,2}[-_/]\d{1,4}');

      // Keep usable columns (preserve order)
      final usableDates = rawDates.where((d) {
        final s = d.toString().toLowerCase().trim();
        return !bannedKeys.contains(s);
      }).toList();

      // Prefer date-like items, but fallback to usableDates if none match
      List<String> filteredDates = usableDates.where((d) {
        return dateLike.hasMatch(d.toString());
      }).toList();
      if (filteredDates.isEmpty) {
        filteredDates = List<String>.from(usableDates);
      }

      final rawAttendanceList = data['attendance'] ?? [];
      final rawAttendance = List<Map<String, dynamic>>.from(rawAttendanceList);

      List<Map<String, dynamic>> normalised = rawAttendance.map((student) {
        final dynamic rawList = student['attendance'] ?? [];

        List<int> att = [];

        if (rawList is Map) {
          // Map case: extract by filteredDates (try variants)
          att = filteredDates.map<int>((d) {
            var val = rawList[d];
            if (val == null) {
              final alt1 = d.replaceAll('_', '-');
              final alt2 = d.replaceAll('-', '_');
              val = rawList[alt1] ?? rawList[alt2];
            }
            if (val == null) {
              for (final k in rawList.keys) {
                if (k.toString().toLowerCase() == d.toString().toLowerCase()) {
                  val = rawList[k];
                  break;
                }
              }
            }
            final parsed = int.tryParse(val?.toString() ?? '') ?? 0;
            return (parsed == 1) ? 1 : 0;
          }).toList();
        } else {
          // List-like case: handle meta + numeric patterns
          final listLike = List.from(rawList);

          // Helper: is this element numeric (int or int-like string)?
          bool isNumericElement(dynamic e) {
            if (e == null) return false;
            if (e is int) return true;
            return int.tryParse(e.toString()) != null;
          }

          final numericIndices = <int>[];
          for (int i = 0; i < listLike.length; i++) {
            if (isNumericElement(listLike[i])) numericIndices.add(i);
          }

          if (numericIndices.isEmpty) {
            // No numeric values at all — fallback to zeros of length filteredDates
            att = List<int>.filled(filteredDates.length, 0);
          } else if (numericIndices.length == listLike.length) {
            // All entries numeric — use them directly (convert to 0/1)
            att = listLike.map<int>((e) {
              final parsed = int.tryParse(e.toString()) ?? 0;
              return (parsed == 1) ? 1 : 0;
            }).toList();
          } else if (numericIndices.length == 1) {
            // Exactly one numeric in a mixed list (your case: ["CS101", "timestamp", 1])
            // Place that numeric at the last date index (most recent) and pad earlier with zeros.
            final val = int.tryParse(listLike[numericIndices[0]].toString()) ?? 0;
            if (filteredDates.isNotEmpty) {
              att = List<int>.filled(filteredDates.length, 0);
              att[filteredDates.length - 1] = (val == 1) ? 1 : 0;
            } else {
              // No dates known — treat as single-day attendance
              att = [(val == 1) ? 1 : 0];
            }
          } else {
            // Multiple numeric values but mixed with meta. Align numeric values to the right
            // so the most recent numeric maps to the latest date.
            final numericValues = numericIndices
                .map((i) => int.tryParse(listLike[i].toString()) ?? 0)
                .toList();
            if (filteredDates.isNotEmpty) {
              att = List<int>.filled(filteredDates.length, 0);
              // Put numericValues at the end (right aligned)
              for (int i = 0; i < numericValues.length; i++) {
                final pos = filteredDates.length - numericValues.length + i;
                if (pos >= 0 && pos < att.length) {
                  att[pos] = (numericValues[i] == 1) ? 1 : 0;
                }
              }
            } else {
              att = numericValues.map((v) => (v == 1) ? 1 : 0).toList();
            }
          }

          // Finally, ensure att length matches filteredDates (trim/pad)
          if (filteredDates.isNotEmpty && att.length != filteredDates.length) {
            if (att.length > filteredDates.length) {
              att = att.sublist(0, filteredDates.length);
            } else {
              att = List<int>.from(att)
                ..addAll(List.filled(filteredDates.length - att.length, 0));
            }
          }
        }

        return {
          'name': student['name'] ?? '',
          'roll_number': student['roll_number'] ?? student['roll'] ?? '',
          'attendance': att,
        };
      }).toList();

      // Edge-case: no dates but attendance exists -> synthesize Day1..N labels
      if (filteredDates.isEmpty) {
        int maxLen = 0;
        for (final s in normalised) {
          final l = (s['attendance'] as List).length;
          if (l > maxLen) maxLen = l;
        }
        if (maxLen > 0) {
          filteredDates = List.generate(maxLen, (i) => 'Day${i + 1}');
        }
      }

      setState(() {
        attendanceData = normalised;
        dates = filteredDates;
      });
    } catch (e) {
      setState(() {
        errorMessage = e.toString();
      });
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  Widget _buildAttendanceTable() {
    // Fixed column widths
    const double srNoWidth = 80.0; // Fixed width for Sr. No.
    const double rollNoWidth = 120.0; // Fixed width for Roll No.
    const double nameWidth = 200.0; // Fixed width for Name
    const double percentageWidth = 100.0; // Fixed width for Percentage
    const double dateWidth = 80.0; // Fixed width for each date column

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.subjectName,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        attendanceData.isEmpty
            ? const Text(
          'No attendance records found.',
          style: TextStyle(fontSize: 18),
        )
            : Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Fixed Columns (Sr.No + Roll No)
            DataTable(
              headingRowHeight: 44,
              dataRowHeight: 44,
              columnSpacing: 0,
              columns: [
                _buildDataColumn('Sr. No.', srNoWidth),
                _buildDataColumn('Roll No.', rollNoWidth),
              ],
              rows: attendanceData.asMap().entries.map((entry) {
                return DataRow(
                  cells: [
                    _buildDataCell((entry.key + 1).toString(), srNoWidth),
                    _buildDataCell(entry.value['roll_number'] ?? '', rollNoWidth),
                  ],
                );
              }).toList(),
              border: TableBorder.all(color: Colors.grey),
            ),
            // Scrollable Columns (Name + Percentage + Dates)
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowHeight: 44,
                  dataRowHeight: 44,
                  columnSpacing: 0,
                  columns: [
                    _buildDataColumn('Name', nameWidth),
                    _buildDataColumn('Percentage', percentageWidth),
                    ...dates.map((date) => _buildDataColumn(date, dateWidth, fontSize: 10)),
                  ],
                  rows: attendanceData.map((student) {
                    final totalClasses = (student['attendance'] as List).length;
                    final attendedClasses =
                        (student['attendance'] as List).where((s) => s == 1).length;
                    final percentage = totalClasses == 0 ? 0 : (attendedClasses / totalClasses) * 100;

                    return DataRow(
                      cells: [
                        _buildDataCell(student['name'] ?? '', nameWidth),
                        _buildDataCell('${percentage.toStringAsFixed(2)}%', percentageWidth),
                        ...dates.map((date) {
                          final dateIndex = dates.indexOf(date);
                          final status = (dateIndex < (student['attendance'] as List).length)
                              ? student['attendance'][dateIndex]
                              : 0;
                          return _buildStatusCell(status, dateWidth);
                        }).toList(),
                      ],
                    );
                  }).toList(),
                  border: TableBorder.all(color: Colors.grey),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // Helper methods for reusable components
  DataColumn _buildDataColumn(String text, double width, {double fontSize = 12}) {
    return DataColumn(
      label: SizedBox(
        width: width,
        child: Center(
          child: Text(
            text,
            style: TextStyle(fontSize: fontSize),
          ),
        ),
      ),
    );
  }

  DataCell _buildDataCell(String text, double width, {double fontSize = 12}) {
    return DataCell(
      SizedBox(
        width: width,
        child: Center(
          child: Text(
            text,
            style: TextStyle(fontSize: fontSize),
          ),
        ),
      ),
    );
  }

  DataCell _buildStatusCell(int status, double width) {
    return DataCell(
      SizedBox(
        width: width,
        child: Center(
          child: Text(
            status == 1 ? '1' : '0',
            style: TextStyle(
              fontSize: 12,
              color: status == 1 ? Colors.green : Colors.red,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Table'),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : errorMessage != null
          ? Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            errorMessage!,
            style: const TextStyle(
              fontSize: 20,
              color: Colors.red,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      )
          : Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(child: _buildAttendanceTable()),
      ),
    );
  }
}
