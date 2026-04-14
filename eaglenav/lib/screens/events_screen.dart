import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

final FlutterLocalNotificationsPlugin fln = FlutterLocalNotificationsPlugin();
bool _notificationsInitialized = false;

Future<void> initEventNotifications() async {
  if (_notificationsInitialized) return;

  try {
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('America/Los_Angeles'));
  } catch (e) {
    debugPrint('TZ init error: $e');
  }

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings();
  const initSettings = InitializationSettings(
    android: androidInit,
    iOS: iosInit,
  );

  await fln.initialize(initSettings);

  final androidImpl =
      fln.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidImpl?.requestNotificationsPermission();

  if (Platform.isAndroid) {
    await androidImpl?.requestExactAlarmsPermission();
  }

  final iosImpl =
      fln.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
  await iosImpl?.requestPermissions(alert: true, badge: true, sound: true);

  _notificationsInitialized = true;
}

Future<void> scheduleDayBefore(String id, String title, String startDateIso) async {
  try {
    final parts = startDateIso.split('-').map(int.parse).toList();
    if (parts.length < 3) return;

    final eventDate = DateTime(parts[0], parts[1], parts[2], 9);
    final notifyTime = eventDate.subtract(const Duration(days: 1));
    if (notifyTime.isBefore(DateTime.now())) return;

    final when = tz.TZDateTime.from(notifyTime, tz.local);

    const androidDetails = AndroidNotificationDetails(
      'eaglenav_events',
      'Event Reminders',
      channelDescription: 'Notifies you the day before bookmarked events',
      importance: Importance.high,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);

    await fln.zonedSchedule(
      id.hashCode,
      'Event tomorrow: $title',
      'Happening on $startDateIso',
      when,
      details,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.dateAndTime,
    );
  } catch (e) {
    debugPrint('⚠️ scheduleDayBefore failed: $e');

    const fallbackDetails = AndroidNotificationDetails(
      'eaglenav_fallback',
      'Fallback Notifications',
      channelDescription: 'Used when scheduling fails',
      importance: Importance.high,
      priority: Priority.high,
    );

    await fln.show(
      id.hashCode,
      'Reminder saved: $title',
      'Event reminder could not be scheduled',
      const NotificationDetails(android: fallbackDetails),
    );
  }
}

Future<void> scheduleOnDay(
  String id,
  String title,
  String startDateIso, {
  int hour = 9,
}) async {
  try {
    final parts = startDateIso.split('-').map(int.parse).toList();
    if (parts.length < 3) return;

    final notifyTime = DateTime(parts[0], parts[1], parts[2], hour);
    if (notifyTime.isBefore(DateTime.now())) return;

    final when = tz.TZDateTime.from(notifyTime, tz.local);

    const androidDetails = AndroidNotificationDetails(
      'eaglenav_events',
      'Event Reminders',
      channelDescription: 'Notifies you for bookmarked events',
      importance: Importance.high,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);

    await fln.zonedSchedule(
      id.hashCode,
      'Today: $title',
      'Happening on $startDateIso',
      when,
      details,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.dateAndTime,
    );
  } catch (e) {
    debugPrint('⚠️ scheduleOnDay failed: $e');

    const fallbackDetails = AndroidNotificationDetails(
      'eaglenav_fallback',
      'Fallback Notifications',
      channelDescription: 'Used when scheduling fails',
      importance: Importance.high,
      priority: Priority.high,
    );

    await fln.show(
      id.hashCode,
      'Reminder saved: $title',
      'Exact alarms not permitted — fallback triggered',
      const NotificationDetails(android: fallbackDetails),
    );
  }
}

Future<void> cancelReminder(String id) async {
  try {
    await fln.cancel(id.hashCode);
  } catch (e) {
    debugPrint('cancelReminder error: $e');
  }
}

const Map<int, String> eventGroupNames = {
  1656: 'University',
  1541: '75th Anniversary',
  836: 'Alumni Association',
  1381: 'Business Forum',
  1561: 'CBE Placement Services',
  436: 'Career Center',
  1346: 'Center for Academic Success',
  76: 'Center for Engagement, Service, and the Public Good',
  11: 'College of Arts & Letters',
  16: 'College of Business and Economics',
  21: 'College of Education',
  26: 'College of ECST',
  96: 'College of Ethnic Studies',
  36: 'College of Natural and Social Sciences',
  606: 'Commencement',
  106: 'Department of Art',
  286: 'Department of Biological Sciences',
  1161: 'Department of Theatre and Dance',
  1551: 'Women’s, Gender & Sexuality Studies',
  1106: 'Diversity, Equity, and Belonging',
  61: 'Division of Student Affairs',
  81: 'Downtown LA',
  731: 'Drupal Training',
  601: 'ECST Student Success Center',
  676: 'Early Entrance Program',
  441: 'Educational Opportunity Program',
  706: 'Dreamers Resource Center',
  1716: 'First-Gen Week',
  1686: 'Global Learning',
  1311: 'Guardian Scholars Program',
  386: 'Housing & Residence Life',
  1771: 'ISSO',
  51: 'IT Services',
  1461: 'IoT Research Lab',
  736: 'LSAMP Program',
  1206: 'M.A.R.S Club',
  781: 'MORE Programs',
  681: 'Scholarships & Fellowships',
  321: 'Natural Science Program',
  846: 'Office for Students with Disabilities',
  656: 'Graduate Studies',
  1151: 'Dean of Students Office',
  1601: 'PRE-Chem Program',
  246: 'School of Nursing',
  481: 'Recruitment',
  1536: 'REU Chemistry',
  1066: 'Graduate School Prep',
  411: 'Risk Management & Safety',
  31: 'Rongxiang Xu College of HHS',
  241: 'School of Kinesiology',
  1621: 'Andrade Rounds Lab',
  511: 'Entrepreneurship & Innovation Center',
  6: 'Honors College',
  86: 'University Library',
  1571: 'Urban Ecology Center',
  471: 'Veterans Resource Center',
  1606: 'Welcome Home',
};

class EventsScreen extends StatefulWidget {
  const EventsScreen({super.key});
  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  final ScrollController _scrollController = ScrollController();
  Timer? _scrollDebounce;
  final List<Map<String, String>> _events = [];
  final List<Map<String, String>> _bookmarkedEvents = [];
  bool _isLoading = false;
  bool _hasMore = true;
  int _page = 0;
  String _selectedFilter = 'all';

  @override
  void initState() {
    super.initState();
    initEventNotifications();
    _loadBookmarks().then((_) async {
      await _loadCachedEvents();
      _loadEvents();
    });
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 200 &&
          !_isLoading &&
          _hasMore &&
          _selectedFilter != 'bookmarked') {
        _scrollDebounce?.cancel();
        _scrollDebounce = Timer(const Duration(milliseconds: 300), _loadEvents);
      }
    });
  }

  @override
  void dispose() {
    _scrollDebounce?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  // ✅ Load bookmarks safely from SharedPreferences
  Future<void> _loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('bookmarked_events') ?? [];

    final decoded = <Map<String, String>>[];
    for (var s in saved) {
      try {
        final map = Map<String, dynamic>.from(json.decode(s));
        decoded.add(map.map((k, v) => MapEntry(k, v.toString())));
      } catch (e) {
        debugPrint("⚠️ Skipped invalid bookmark: $e");
      }
    }

    // sort by soonest date
    decoded.sort((a, b) {
      final da = _parseToIso(a['Date'] ?? '');
      final db = _parseToIso(b['Date'] ?? '');
      if (da == null) return 1;
      if (db == null) return -1;
      return DateTime.parse(da).compareTo(DateTime.parse(db));
    });

    setState(() {
      _bookmarkedEvents
        ..clear()
        ..addAll(decoded);
    });
  }

  // ✅ Always save clean, de-duplicated bookmarks
  Future<void> _saveBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final unique = {
      for (var e in _bookmarkedEvents) e['Link'] ?? e['Title'] ?? '': e
    }.values.toList();

    final encoded = unique.map((e) => json.encode(e)).toList();
    await prefs.setStringList('bookmarked_events', encoded);
  }

  Future<void> _loadCachedEvents() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getStringList('cached_events') ?? [];
    if (cached.isEmpty) return;
    final decoded = <Map<String, String>>[];
    for (var s in cached) {
      try {
        final map = Map<String, dynamic>.from(json.decode(s));
        decoded.add(map.map((k, v) => MapEntry(k, v.toString())));
      } catch (_) {}
    }
    if (decoded.isNotEmpty && mounted) {
      setState(() => _events.addAll(decoded));
    }
  }

  Future<void> _cacheEvents() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _events.map((e) => json.encode(e)).toList();
    await prefs.setStringList('cached_events', encoded);
  }

  // 🔹 Load events from website
  Future<void> _loadEvents({bool refresh = false}) async {
    if (_selectedFilter == 'bookmarked') {
      await _loadBookmarks();
      return;
    }

    if (_isLoading) return;

    if (refresh) {
      _page = 0;
      _events.clear();
      _hasMore = true;
    }

    setState(() => _isLoading = true);

    final List<int> allGroups = eventGroupNames.keys.toList();
    final groupId =
        _selectedFilter == 'all' ? allGroups.first : int.parse(_selectedFilter);

    final url =
        "https://www.calstatela.edu/events-group/univ/calendar/list?group_id=$groupId&category=All&page=$_page";

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) throw Exception("Failed to fetch");

      final document = html.parse(response.body);
      final eventElements = document.querySelectorAll('.event-wrapper');

      if (eventElements.isEmpty) {
        _hasMore = false;
      } else {
        for (var e in eventElements) {
          final date = e.querySelector('.event-date')?.text.trim() ?? '';
          final title = e.querySelector('.event-title')?.text.trim() ?? '';
          final desc = e.querySelector('.event-description')?.text.trim() ?? '';
          final linkTag = e.querySelector('.event-title a');
          final link = linkTag?.attributes['href'] ?? '';
          final fullLink =
              link.startsWith('/') ? 'https://www.calstatela.edu$link' : link;

          if (!_events.any((ev) => ev['Link'] == fullLink)) {
            _events.add({
              'Title': title,
              'Date': date,
              'Description': desc,
              'Link': fullLink,
              'Group': eventGroupNames[groupId] ?? 'Unknown',
            });
          }
        }
        _page++;
        _cacheEvents();
      }
    } catch (e) {
      debugPrint("Scrape error: $e");
    }

    setState(() => _isLoading = false);
  }

  // 🔹 Date parsing helper
  String? _parseToIso(String dateText) {
    try {
      if (dateText.isEmpty) return null;

      // Example inputs:
      // "Nov 4, 2025", "Nov 4 2025", "November 4, 2025", "Nov 4, 2025 - 12:00 PM"
      final cleaned = dateText
          .replaceAll(RegExp(r'(\s*-\s*.*)'), '') // remove time parts
          .replaceAll(',', '')
          .trim();

      final parts = cleaned.split(' ');
      if (parts.length < 2) return null;

      final monthMap = {
        'Jan': 1, 'January': 1,
        'Feb': 2, 'February': 2,
        'Mar': 3, 'March': 3,
        'Apr': 4, 'April': 4,
        'May': 5,
        'Jun': 6, 'June': 6,
        'Jul': 7, 'July': 7,
        'Aug': 8, 'August': 8,
        'Sep': 9, 'Sept': 9, 'September': 9,
        'Oct': 10, 'October': 10,
        'Nov': 11, 'November': 11,
        'Dec': 12, 'December': 12,
      };

      final month = monthMap[parts[0]] ?? 1;
      final day = int.tryParse(parts[1]) ?? 1;
      final year = (parts.length >= 3) ? int.tryParse(parts[2]) ?? DateTime.now().year : DateTime.now().year;

      return DateTime(year, month, day).toIso8601String().split('T').first;
    } catch (e) {
      debugPrint("❌ Date parse failed for '$dateText': $e");
      return null;
    }
  }


  // 🔹 Add or remove bookmark
  Future<void> _toggleBookmark(Map<String, String> event) async {
    final idBase = event['Link'] ?? event['Title'] ?? 'unknown';
    final date = event['Date'] ?? '';
    final startDateIso = _parseToIso(date);

    final alreadyBookmarked =
        _bookmarkedEvents.any((e) => e['Link'] == event['Link']);

    if (alreadyBookmarked) {
      await cancelReminder('${idBase}_day_before');
      await cancelReminder('${idBase}_day_of');
      _bookmarkedEvents.removeWhere((e) => e['Link'] == event['Link']);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Removed bookmark for ${event['Title']}")),
      );
    } else {
      if (startDateIso != null) {
        await scheduleDayBefore(
            '${idBase}_day_before', event['Title'] ?? '', startDateIso);
        await scheduleOnDay(
            '${idBase}_day_of', event['Title'] ?? '', startDateIso, hour: 9);

        final cleanEvent = {
          'Title': event['Title'] ?? '',
          'Date': event['Date'] ?? '',
          'Description': event['Description'] ?? '',
          'Link': event['Link'] ?? '',
          'Group': event['Group'] ?? '',
        };

        _bookmarkedEvents.add(cleanEvent);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Bookmarked ${event['Title']}")),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Invalid date, cannot schedule")),
        );
      }
    }

    await _saveBookmarks();
    if (_selectedFilter == 'bookmarked') await _loadBookmarks();
    setState(() {});
  }

  // 🔹 Return appropriate event list
  List<Map<String, String>> _filteredEvents() {
    return _selectedFilter == 'bookmarked' ? _bookmarkedEvents : _events;
  }

  // 🔹 Build UI
  @override
  Widget build(BuildContext context) {
    super.build(context);
    final eventsToShow = _filteredEvents();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color.fromARGB(255, 161, 133, 40),
        title: const Text("Events",
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 20,
                color: Colors.white)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10.0),
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color.fromARGB(255, 140, 110, 30)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedFilter,
                  isDense: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  icon: const Icon(Icons.arrow_drop_down, color: Colors.black87),
                  style: const TextStyle(
                      color: Colors.black87,
                      fontSize: 14,
                      fontWeight: FontWeight.w500),
                  onChanged: (value) async {
                    setState(() {
                      _selectedFilter = value!;
                      _page = 0;
                      _hasMore = true;
                    });
                    if (_selectedFilter == 'bookmarked') {
                      await _loadBookmarks();
                    } else {
                      await _loadEvents(refresh: true);
                    }
                  },
                  items: [
                    const DropdownMenuItem(value: 'all', child: Text("All")),
                    const DropdownMenuItem(
                        value: 'bookmarked', child: Text("Bookmarked")),
                    ...eventGroupNames.entries.map(
                      (e) => DropdownMenuItem(
                        value: e.key.toString(),
                        child: Text(e.value, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (_selectedFilter == 'bookmarked') {
            await _loadBookmarks();
          } else {
            await _loadEvents(refresh: true);
          }
        },
        child: eventsToShow.isEmpty && !_isLoading
            ? Center(
                child: Text(
                  _selectedFilter == 'bookmarked'
                      ? "No bookmarks yet"
                      : "No events found",
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w500),
                ),
              )
            : ListView.builder(
                controller: _scrollController,
                itemCount: eventsToShow.length + (_isLoading ? 1 : 0),
                itemBuilder: (context, i) {
                  if (i == eventsToShow.length) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }

                  final e = eventsToShow[i];
                  final bookmarked =
                      _bookmarkedEvents.any((b) => b['Link'] == e['Link']);

                  return Card(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    elevation: 3,
                    child: ListTile(
                      title: Text(e['Title'] ?? '',
                          style:
                              const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e['Date'] ?? 'No date',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w500)),
                          const SizedBox(height: 4),
                          Text(e['Description'] ?? '',
                              maxLines: 3, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 4),
                          Text(e['Group'] ?? '',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                      trailing: IconButton(
                        icon: Icon(
                          bookmarked
                              ? Icons.bookmark
                              : Icons.bookmark_outline,
                          color:
                              bookmarked ? Colors.amber[700] : Colors.grey[600],
                        ),
                        onPressed: () => _toggleBookmark(e),
                      ),
                      onTap: () async {
                        final link = e['Link'] ?? '';
                        if (link.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("No link available")),
                          );
                          return;
                        }

                        final uri = Uri.tryParse(link);
                        if (uri == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Invalid link: $link")),
                          );
                          return;
                        }

                        try {
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri,
                                mode: LaunchMode.externalApplication);
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text("Cannot open: $link")),
                            );
                          }
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Error opening link: $e")),
                          );
                        }
                      },
                    ),
                  );
                },
              ),
      ),
    );
  }
}
