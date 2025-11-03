import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html;
import 'package:url_launcher/url_launcher.dart';
import '../main.dart';

// 🔹 Group ID → readable category names
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

class _EventsScreenState extends State<EventsScreen> {
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, String>> _events = [];
  final Set<String> _bookmarked = {};
  bool _isLoading = false;
  bool _hasMore = true;
  int _page = 0;
  String _selectedFilter = 'all'; // 'all', 'bookmarked', or group ID string

  @override
  void initState() {
    super.initState();
    _loadEvents();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 200 &&
          !_isLoading &&
          _hasMore &&
          _selectedFilter != 'bookmarked') {
        _loadEvents();
      }
    });
  }

  Future<void> _loadEvents() async {
    if (_isLoading || _selectedFilter == 'bookmarked') return;
    setState(() => _isLoading = true);

    final List<int> allGroups = eventGroupNames.keys.toList();
    final groupId = _selectedFilter == 'all'
        ? allGroups[_page % allGroups.length]
        : int.parse(_selectedFilter);
    final url =
        "https://www.calstatela.edu/events-group/univ/calendar/list?group_id=$groupId&category=All&page=${(_page ~/ allGroups.length)}";

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) throw Exception("Failed to fetch");
      final document = html.parse(response.body);
      final eventElements = document.querySelectorAll('.event-wrapper');

      if (eventElements.isEmpty) {
        setState(() => _hasMore = false);
      } else {
        for (var e in eventElements) {
          final date = e.querySelector('.event-date')?.text.trim() ?? '';
          final title = e.querySelector('.event-title')?.text.trim() ?? '';
          final desc = e.querySelector('.event-description')?.text.trim() ?? '';
          final linkTag = e.querySelector('.event-title a');
          final link = linkTag?.attributes['href'] ?? '';
          final fullLink =
              link.startsWith('/') ? 'https://www.calstatela.edu$link' : link;

          if (!_events.any((ev) => ev['Title'] == title)) {
            _events.add({
              'Title': title,
              'Date': date,
              'Description': desc,
              'Link': fullLink,
              'Group': eventGroupNames[groupId] ?? 'Unknown'
            });
          }
        }
        _page++;
      }
    } catch (e) {
      debugPrint("Scrape error: $e");
    }

    setState(() => _isLoading = false);
  }

  Future<void> _openEventLink(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Could not open link: $url")),
      );
    }
  }

  String? _parseToIso(String dateText) {
    try {
      if (dateText.isEmpty) return null;
      final firstPart = dateText.split('to').first.trim();
      final cleaned = firstPart.replaceAll(RegExp(r'[^\w\s,]'), '').trim();
      final monthMap = {
        'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
        'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
      };
      final parts = cleaned.split(' ');
      if (parts.length >= 3) {
        final month = monthMap[parts[0].substring(0, 3)] ?? 1;
        final day = int.tryParse(parts[1].replaceAll(',', '')) ?? 1;
        final year = int.tryParse(parts.last) ?? DateTime.now().year;
        return DateTime(year, month, day).toIso8601String().split('T').first;
      }
    } catch (e) {
      debugPrint("Date parse failed for '$dateText': $e");
    }
    return null;
  }

  Future<void> _toggleBookmark(Map<String, String> event) async {
    final id = event['Title'] ?? 'unknown';
    final date = event['Date'] ?? '';
    final startDateIso = _parseToIso(date);

    if (_bookmarked.contains(id)) {
      await cancelReminder(id);
      _bookmarked.remove(id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Removed bookmark for ${event['Title']}")),
      );
    } else {
      if (startDateIso != null) {
        await scheduleDayBefore(id, event['Title'] ?? '', startDateIso);
        _bookmarked.add(id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Bookmarked ${event['Title']}")),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Invalid date, cannot schedule")),
        );
      }
    }
    setState(() {});
  }

  List<Map<String, String>> _filteredEvents() {
    if (_selectedFilter == 'bookmarked') {
      return _events.where((e) => _bookmarked.contains(e['Title'])).toList();
    }
    return _events;
  }

  @override
  Widget build(BuildContext context) {
    final eventsToShow = _filteredEvents();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color.fromARGB(255, 161, 133, 40),
        title: const Text(
          "Events",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 20,
            color: Colors.white,
          ),
        ),
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
                    fontWeight: FontWeight.w500,
                  ),
                  onChanged: (value) {
                    setState(() {
                      _selectedFilter = value!;
                      _events.clear();
                      _page = 0;
                      _hasMore = true;
                    });
                    _loadEvents();
                  },
                  items: [
                    const DropdownMenuItem(
                      value: 'all',
                      child: Text("All Categories"),
                    ),
                    const DropdownMenuItem(
                      value: 'bookmarked',
                      child: Text("Bookmarked"),
                    ),
                    ...eventGroupNames.entries.map(
                      (e) => DropdownMenuItem(
                        value: e.key.toString(),
                        child: Text(
                          e.value,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: eventsToShow.isEmpty && !_isLoading
          ? const Center(child: Text("No events found"))
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
                final bookmarked = _bookmarked.contains(e['Title']);

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  elevation: 3,
                  child: ListTile(
                    title: Text(
                      e['Title'] ?? '',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e['Date'] ?? 'No date',
                            style: const TextStyle(fontWeight: FontWeight.w500)),
                        const SizedBox(height: 4),
                        Text(
                          e['Description'] ?? '',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          e['Group'] ?? '',
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                    trailing: IconButton(
                      icon: Icon(
                        bookmarked ? Icons.bookmark : Icons.bookmark_outline,
                        color: bookmarked ? Colors.amber[700] : Colors.grey[600],
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
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
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
    );
  }
}
