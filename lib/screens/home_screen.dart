import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_math_fork/flutter_math.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart'; // for Clipboard
import 'dart:typed_data';
import 'admin_dashboard.dart';
import 'pdf_viewer.dart';
import 'student_upload.dart';
// TODO: Move this to --dart-define for production

class Flashcard {
  final String question;
  final String answer;
  final List<String> options;
  final int correctIndex;

  Flashcard({
    required this.question,
    required this.answer,
    this.options = const [],
    this.correctIndex = 0,
  });
}

void _showSimpleToast(BuildContext context, {required bool success}) {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Positioned(
      left: 24,
      right: 24,
      bottom: MediaQuery.of(context).viewInsets.bottom + 28,
      child: IgnorePointer(
        child: Material(
          color: Colors.transparent,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              decoration: BoxDecoration(
                color: success ? Colors.green.shade600 : Colors.red.shade600,
                borderRadius: BorderRadius.circular(28),
                boxShadow: const [
                  BoxShadow(blurRadius: 12, offset: Offset(0, 5), color: Colors.black26),
                ],
              ),
              child: Text(
                success ? 'Successful!' : 'Something went wrong!',
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future.delayed(const Duration(seconds: 2), () {
    if (entry.mounted) entry.remove();
  });
}

// -----------------------------------------------------------------------------
// HELPER: Auto-detect and render LaTeX without $ signs
// -----------------------------------------------------------------------------

Widget _buildMathText(String text, {TextStyle? style, TextAlign align = TextAlign.left,}) {
  String _clean(String input) {
    String s = input;
    s = s.replaceAll(RegExp(r'\*\*|\*|`|_'), '');
    s = s.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}');
    s = s.replaceAllMapped(RegExp(r'([a-zA-Z])(\d)'), (m) => '${m[1]} ${m[2]}');
    s = s.replaceAllMapped(RegExp(r'(\d)([a-zA-Z])'), (m) => '${m[1]} ${m[2]}');
    s = s.replaceAll('Chas', 'C has ').replaceAll('has', 'has ');
    s = s.replaceAll(':', ': ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  final List<Widget> widgets = [];
  final List<String> lines = text.split('\n');
  for (int i = 0; i < lines.length; i++) {
    final String rawLine = lines[i];
    final String line = _clean(rawLine).trim();
    if (line.isEmpty) continue;
    
    final bool looksLikeMath = RegExp(r'[=^_]|\\frac|\\sqrt|\\alpha|\\beta|\\gamma|\\pi|\\theta|\\pm',).hasMatch(line) && line.length < 150;
    
    if (looksLikeMath) {
      try {
        widgets.add(
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Math.tex(line, mathStyle: MathStyle.display, textStyle: style?.copyWith(fontSize: (style.fontSize ?? 16) + 2,),),
              ),
            ),
          ),
        );
      } catch (e) {
        widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            line,
            style: style?.copyWith(height: 1.6),
            textAlign: align,
            softWrap: true,
          ),
        ),
      );
      }
    } else {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            line,
            style: style?.copyWith(height: 1.6),
            textAlign: align,
            softWrap: true,
          ),
        ),
      );
    }
    if (i < lines.length - 1) widgets.add(const SizedBox(height: 2));
  }
  return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: widgets,);
}

class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 22),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (_, __) {
              final width = constraints.maxWidth;
              final dx = -(width * _controller.value);
              return Transform.translate(
                offset: Offset(dx, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: width * 2,
                    child: Center(
                      child: Text(
                        '${widget.text}     ✦     ${widget.text}',
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: widget.style,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class HomeScreen extends StatefulWidget {
  final String geminiApiKey;
  const HomeScreen({super.key, required this.geminiApiKey});
  
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _requestController = TextEditingController();
  String selectedCourse = 'All';
  String searchQuery = '';
  final Set<String> likedDocs = {};
  final Set<String> ratedDocs = {};
  final Set<String> _likeInProgress = {};
  final Set<String> _rateInProgress = {};
  final Set<String> _viewInProgress = {};
  Set<String> favoriteDocs = {};
  Set<String> recentlyViewed = {};
  List<String> myUploads = [];
  String _themeMode = 'light';
  int _tapCount = 0;
  DateTime? _lastTapTime;
  final List<Color> _cardColors = [
    const Color(0xFF00C896), const Color(0xFF3B82F6), const Color(0xFFF59E0B),
    const Color(0xFFEC4899), const Color(0xFF8B5CF6),
  ];

  GenerativeModel? model;
  List<Map<String, String>> _dailyQuotes = [];
  bool _quotesLoading = true;

  @override
  void initState() {
    super.initState();
    
    // AI is optional at startup. A missing API key must not prevent the
    // main ExamHook app from opening.
    final String apiKey = widget.geminiApiKey.trim();
    if (apiKey.isNotEmpty) {
      model = GenerativeModel(
        model: 'gemini-3.6-flash',
        apiKey: apiKey,
      );
    } else {
      debugPrint('Gemini API key not supplied; AI features are disabled.');
    }
    
    _loadPrefs();
    _loadDailyQuotes();
  }
  
  @override
  void dispose() {
    _searchController.dispose();
    _requestController.dispose();
    super.dispose();
  }
  
  // ---------------------------------------------------------------------------
  // SIMPLE TOAST + DAILY CLOUD MOTIVATION
  // ---------------------------------------------------------------------------
  void _showToast({required bool success}) {
    if (!mounted) return;
    final OverlayState? overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        left: 24,
        right: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 28,
        child: IgnorePointer(
          child: Material(
            color: Colors.transparent,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                decoration: BoxDecoration(
                  color: success ? Colors.green.shade600 : Colors.red.shade600,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const [
                    BoxShadow(blurRadius: 12, offset: Offset(0, 5), color: Colors.black26),
                  ],
                ),
                child: Text(
                  success ? 'Successful!' : 'Something went wrong!',
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 2), () {
      if (entry.mounted) entry.remove();
    });
  }

  Future<void> _loadDailyQuotes() async {
    // Always keep a message available so the marquee never disappears.
    // The message changes automatically each calendar day.
    try {
      final SharedPreferences prefs =
          await SharedPreferences.getInstance();
      final DateTime now = DateTime.now();
      final String dateKey =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';

      final String? savedDate = prefs.getString('daily_motivation_date');
      final String? savedQuote = prefs.getString('daily_motivation_quote');
      final String? savedAuthor = prefs.getString('daily_motivation_author');

      if (savedDate == dateKey && savedQuote != null && savedQuote.trim().isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _dailyQuotes = [
            {
              'quote': savedQuote.trim(),
              'author': (savedAuthor ?? 'ExamHook AI').trim(),
            },
          ];
          _quotesLoading = false;
        });
        return;
      }

      String quote = '';
      String author = 'ExamHook AI';

      final GenerativeModel? aiModel = model;
      if (aiModel != null) {
        try {
          final response = await aiModel.generateContent([
            Content.text(
              '''Create one original motivational statement for a high-school student studying today.
Date: $dateKey
Rules:
- Return only the motivational statement.
- Maximum 22 words.
- No quotation marks, hashtags, emojis, politics, or famous quotes.
- Make it encouraging and focused on learning, consistency, understanding, and progress.''',
            ),
          ]);
          quote = (response.text ?? '')
              .replaceAll(RegExp(r'^["“]|["”]$'), '')
              .trim();
          if (quote.length > 180) {
            quote = quote.substring(0, 180).trim();
          }
        } catch (e) {
          debugPrint('AI daily motivation error: $e');
        }
      }

      // Offline/no-key fallback. The date seed makes the message change daily
      // without changing the rest of the HomeScreen scope.
      if (quote.isEmpty) {
        const fallback = <String>[
          'Small progress each day builds the knowledge you need for success.',
          'Study with purpose today, and let your future self thank you tomorrow.',
          'Every question you solve is another step toward mastering your goals.',
          'Consistency turns difficult topics into familiar ones.',
          'Keep learning, keep practising, and keep moving forward.',
          'Your effort today is building the skills you will use tomorrow.',
          'Focus on understanding, not just memorising, and progress will follow.',
          'A little revision every day can make a big difference over time.',
          'Mistakes are part of learning; use them to discover what to improve.',
          'Believe in your ability to learn, then prove it through steady practice.',
        ];
        final int seed = now.year * 10000 + now.month * 100 + now.day;
        quote = fallback[math.Random(seed).nextInt(fallback.length)];
        author = 'ExamHook';
      }

      await prefs.setString('daily_motivation_date', dateKey);
      await prefs.setString('daily_motivation_quote', quote);
      await prefs.setString('daily_motivation_author', author);

      if (!mounted) return;
      setState(() {
        _dailyQuotes = [
          {'quote': quote, 'author': author},
        ];
        _quotesLoading = false;
      });
    } catch (e) {
      debugPrint('Daily motivation error: $e');
      if (!mounted) return;
      setState(() {
        _dailyQuotes = [
          {
            'quote': 'Keep learning, keep practising, and keep moving forward.',
            'author': 'ExamHook',
          },
        ];
        _quotesLoading = false;
      });
    }
  }

  Widget _buildDailyQuotesMarquee(bool isDark) {
    final List<Map<String, String>> messages = _dailyQuotes.isEmpty
        ? const [
            {
              'quote': 'Keep learning, keep practising, and keep moving forward.',
              'author': 'ExamHook',
            },
          ]
        : _dailyQuotes;
    final text = messages
        .map((q) => '“${q['quote']}” — ${q['author']}')
        .join('     ✦     ');
    return Container(
      height: 64,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF00C896), Color(0xFF3B82F6), Color(0xFF8B5CF6)],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(blurRadius: 10, offset: Offset(0, 4), color: Colors.black12)],
      ),
      clipBehavior: Clip.antiAlias,
      child: _MarqueeText(
        text: text,
        style: GoogleFonts.poppins(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Future<void> _loadPrefs() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _themeMode = prefs.getString('theme_mode') ?? 'light';
        likedDocs.addAll(prefs.getStringList('liked_resources') ?? []);
        ratedDocs.addAll(prefs.getStringList('rated_resources') ?? []);
        favoriteDocs = Set<String>.from(prefs.getStringList('favorites') ?? []);
        recentlyViewed = Set<String>.from(prefs.getStringList('recent') ?? []);
        myUploads = prefs.getStringList('my_uploads') ?? [];
      });
      await _checkTerms();
    } catch (e) {
      debugPrint('Prefs error: $e');
    }
  }
  
  Future<void> _checkTerms() async { // <-- ONLY 1 DECLARATION
    // put your terms check logic here
    final prefs = await SharedPreferences.getInstance();
    bool accepted = prefs.getBool('terms_accepted') ?? false;
    if(!accepted && mounted) {
      // show dialog
    }
  }
  
  Future<void> _clearUploadHistory() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove('my_uploads');
      if (!mounted) return;
      setState(() {myUploads.clear();});
      _showToast(success: true);
    } catch (e) {
      if (!mounted) return;
      _showToast(success: false);
    }
  }
  
  String _normalizeUploadValue(dynamic value) => value?.toString().trim().toLowerCase() ?? '';
  
  bool _isMyUpload(QueryDocumentSnapshot doc) {
    final dynamic rawData = doc.data();
    if (rawData is! Map) return false;
    final Map<String, dynamic> data = Map<String, dynamic>.from(rawData);
    final Set<String> documentIdentifiers = {
      _normalizeUploadValue(doc.id), _normalizeUploadValue(data['id']),
      _normalizeUploadValue(data['fileName']), _normalizeUploadValue(data['fileUrl']),
      _normalizeUploadValue(data['url']), _normalizeUploadValue(data['title']),
      _normalizeUploadValue(data['uploadId']), _normalizeUploadValue(data['resourceId']),
    };
    documentIdentifiers.removeWhere((value) => value.isEmpty);
    for (final String savedUpload in myUploads) {
      final String normalizedSaved = _normalizeUploadValue(savedUpload);
      if (normalizedSaved.isEmpty) continue;
      if (documentIdentifiers.contains(normalizedSaved)) return true;
      for (final String identifier in documentIdentifiers) {
        if (identifier == normalizedSaved) return true;
        if (identifier.endsWith(normalizedSaved) || normalizedSaved.endsWith(identifier)) return true;
      }
    }
    return false;
  }
  
  String _getUploadStatus(QueryDocumentSnapshot doc, {required bool isPendingCollection,}) {
    final dynamic rawData = doc.data();
    if (rawData is! Map) return isPendingCollection ? 'Pending' : 'Approved';
    final Map<String, dynamic> data = Map<String, dynamic>.from(rawData);
    final dynamic rawStatus = data['status'] ?? data['uploadStatus'] ?? data['reviewStatus'];
    final String status = rawStatus?.toString().trim().toLowerCase() ?? '';
    if (status.contains('reject')) return 'Rejected';
    if (status.contains('pending') || status.contains('review') || status.contains('waiting')) return 'Pending';
    if (status.contains('approv')) return 'Approved';
    if (isPendingCollection) return 'Pending';
    return 'Approved';
  }
  
  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'approved': return Colors.green;
      case 'rejected': return Colors.red;
      case 'pending': default: return Colors.orange;
    }
  }
  
  IconData _getStatusIcon(String status) {
    switch (status.toLowerCase()) {
      case 'approved': return Icons.check_circle;
      case 'rejected': return Icons.cancel;
      case 'pending': default: return Icons.pending;
    }
  }

  // RECENT / FAVORITES / THEME
  // ---------------------------------------------------------------------------
  Future<void> _saveRecent(String docId) async {
    try {
      final SharedPreferences prefs =
          await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        recentlyViewed.remove(docId);
        recentlyViewed.add(docId);
        if (recentlyViewed.length > 10) {
          recentlyViewed.remove(recentlyViewed.first);
        }
      });
      await prefs.setStringList(
        'recent',
        recentlyViewed.toList(),
      );
    } catch (e) {
      debugPrint('Recent error: $e');
    }
  }
  Future<void> _toggleFavorite(String docId) async {
    try {
      final SharedPreferences prefs =
          await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        if (favoriteDocs.contains(docId)) {
          favoriteDocs.remove(docId);
        } else {
          favoriteDocs.add(docId);
        }
      });
      await prefs.setStringList(
        'favorites',
        favoriteDocs.toList(),
      );
    } catch (e) {
      debugPrint('Favorite error: $e');
    }
  }
  Future<void> _saveTheme(String theme) async {
    final SharedPreferences prefs =
        await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', theme);
    if (!mounted) return;
    setState(() {
      _themeMode = theme;
    });
  }
  // ---------------------------------------------------------------------------
  // TERMS
  // ---------------------------------------------------------------------------

  void _showTermsDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            'Terms & Conditions',
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SingleChildScrollView(
            child: Text(
              'By using ExamHook you agree to:\n\n'
              '1. Resources are for educational purposes only.\n'
              '2. Do not redistribute files without permission.\n'
              '3. Admin reserves the right to remove content.\n'
              '4. We collect anonymous usage stats to improve the app.',
              style: GoogleFonts.poppins(
                fontSize: 14,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final SharedPreferences prefs =
                    await SharedPreferences.getInstance();
                await prefs.setBool(
                  'terms_accepted',
                  true,
                );
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
              },
              child: const Text(
                'Accept',
                style: TextStyle(
                  color: Color(0xFF00C896),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
  // ---------------------------------------------------------------------------
  // REQUEST NOTES
  // ---------------------------------------------------------------------------
  void _showRequestDialog() {
    _requestController.clear();
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            'Request Notes',
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: TextField(
            controller: _requestController,
            decoration: const InputDecoration(
              labelText: 'What subject/topic do you need?',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final String request =
                    _requestController.text.trim();
                if (request.isEmpty) {
                  return;
                }
                try {
                  await _firestore.collection('requests').add({
                    'subject': request,
                    'message': 'User requested: $request',
                    'timestamp': FieldValue.serverTimestamp(),
                    'status': 'pending',
                  });
                  if (dialogContext.mounted) {
                    Navigator.pop(dialogContext);
                  }
                  if (!mounted) return;
                  _showToast(success: true);
                } catch (e) {
                  if (!mounted) return;
                  _showToast(success: false);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00C896),
              ),
              child: const Text('Send Request'),
            ),
          ],
        );
      },
    );
  }
  // ---------------------------------------------------------------------------
  // OPEN RESOURCE
  // ---------------------------------------------------------------------------
  Future<void> _openResource(
    String docId,
    String url,
    String title, {
    bool countDownload = true,
  }) async {
    if (url.trim().isEmpty) {
      if (mounted) _showToast(success: false);
      return;
    }

    if (_viewInProgress.contains(docId)) return;
    _viewInProgress.add(docId);

    try {
      await _saveRecent(docId);

      final Uri uri = Uri.tryParse(url.trim()) ?? Uri();
      if (uri.toString().isEmpty) {
        throw Exception('Invalid resource URL');
      }

      bool opened = false;

      if (kIsWeb) {
        opened = await canLaunchUrl(uri);
        if (opened) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      } else {
        final String path = uri.path.toLowerCase();
        final bool isPdf = path.endsWith('.pdf') || path.contains('.pdf/');

        if (isPdf) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PdfViewerScreen(
                url: url.trim(),
                title: title,
              ),
            ),
          );
          opened = true;
        } else if (await canLaunchUrl(uri)) {
          await launchUrl(
            uri,
            mode: LaunchMode.externalApplication,
          );
          opened = true;
        }
      }

      // Count the download only after the resource has actually been opened.
      // SharedPreferences stores the lock so reopening/restarting the app
      // cannot increment the same resource again on this installation.
      if (opened && countDownload) {
        final SharedPreferences prefs =
            await SharedPreferences.getInstance();
        final String key = 'resource_download_counted_$docId';
        final bool alreadyCounted = prefs.getBool(key) ?? false;

        if (!alreadyCounted) {
          await _firestore.collection('resources').doc(docId).update({
            'downloads': FieldValue.increment(1),
          });
          await prefs.setBool(key, true);
        }
      }

      if (mounted) {
        _showToast(success: opened);
      }
    } catch (e) {
      debugPrint('Open resource error: $e');
      if (mounted) _showToast(success: false);
    } finally {
      _viewInProgress.remove(docId);
    }
  }

  // ---------------------------------------------------------------------------
  // AI FLASHCARDS FROM PDF
  // ---------------------------------------------------------------------------
  Future<void> _generateFlashcardsFromPdf(
    String pdfUrl,
    String title,
  ) async {
    final GenerativeModel? aiModel = model;
    if (aiModel == null) {
      if (mounted) {
        _showToast(success: false);
      }
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return const Center(
          child: CircularProgressIndicator(),
        );
      },
    );
    bool dialogClosed = false;
    try {
      final http.Response response =
          await http.get(Uri.parse(pdfUrl));
      if (response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw Exception(
          'Could not download PDF (${response.statusCode})',
        );
      }
      final Uint8List pdfBytes = response.bodyBytes;
      final TextPart prompt = TextPart(
        r'''
Generate 10 multiple-choice flashcards from this PDF for high school exam prep.
Rules:
1. Return ONLY a valid JSON array. No markdown, no asterisks, no explanation.
2. Format: [{"q":"question","a":"correct answer","options":["option 1","option 2","option 3","option 4"],"correctIndex":0}]
3. Every card MUST have exactly 4 distinct options.
4. One option MUST exactly match the correct answer in "a".
5. correctIndex is the zero-based index of the correct option.
6. For formulas write them in plain LaTeX without $ signs. Example: F = ma, E = mc^2, \frac{a}{b}, x^2
7. Keep answers short, max 15 words.
''',
      );
      final DataPart pdfData = DataPart(
        'application/pdf',
        pdfBytes,
      );
      final GenerateContentResponse result =
          await aiModel.generateContent(
        [
          Content.multi([
            prompt,
            pdfData,
          ]),
        ],
      );
      if (mounted) {
        Navigator.pop(context);
        dialogClosed = true;
      }
      String text = result.text ?? '';
      text = text
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();
      final dynamic decoded = jsonDecode(text);
      if (decoded is! List) {
        throw Exception(
          'AI returned invalid flashcard data',
        );
      }
      final List<Flashcard> cards = decoded
          .whereType<Map>()
          .map(
            (e) => Flashcard(
              question: e['q']?.toString() ?? '',
              answer: e['a']?.toString() ?? '',
              options: e['options'] is List
                  ? List<String>.from((e['options'] as List).map((v) => v.toString()))
                  : const [],
              correctIndex: e['correctIndex'] is int
                  ? e['correctIndex'] as int
                  : int.tryParse(e['correctIndex']?.toString() ?? '') ?? 0,
            ),
          )
          .where(
            (card) =>
                card.question.isNotEmpty &&
                card.answer.isNotEmpty,
          )
          .toList();
      if (cards.isEmpty) {
        throw Exception('No flashcards were generated');
      }
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _FlashcardDialogFromList(
            cards: cards,
            title: title,
          ),
        ),
      );
    } catch (e) {
      if (mounted && !dialogClosed) {
        Navigator.pop(context);
      }
      if (mounted) {
        _showToast(success: false);
      }
    }
  }
  // ---------------------------------------------------------------------------
  // SHARE / LIKE / RATE
  // ---------------------------------------------------------------------------
  void _shareResource(
    String title,
    String url,
  ) {
    // Do not expose the Supabase storage/bucket URL in the user-facing share text.
    Share.share(
      'Check out "$title" on ExamHook',
    );
  }
  Future<void> _likeResource(String docId) async {
    if (likedDocs.contains(docId) || _likeInProgress.contains(docId)) {
      return;
    }

    _likeInProgress.add(docId);
    try {
      final SharedPreferences prefs =
          await SharedPreferences.getInstance();
      final String key = 'resource_like_counted_$docId';

      if (prefs.getBool(key) ?? false) {
        if (mounted) {
          setState(() => likedDocs.add(docId));
        }
        return;
      }

      await _firestore.collection('resources').doc(docId).update({
        'likes': FieldValue.increment(1),
      });

      await prefs.setBool(key, true);
      final List<String> savedLikes =
          prefs.getStringList('liked_resources') ?? [];
      if (!savedLikes.contains(docId)) {
        savedLikes.add(docId);
        await prefs.setStringList('liked_resources', savedLikes);
      }

      if (!mounted) return;
      setState(() => likedDocs.add(docId));
    } catch (e) {
      debugPrint('Like error: $e');
    } finally {
      _likeInProgress.remove(docId);
    }
  }

  Future<void> _rateResource(
    String docId,
    double rating,
  ) async {
    if (ratedDocs.contains(docId) || _rateInProgress.contains(docId)) {
      return;
    }

    _rateInProgress.add(docId);
    try {
      final SharedPreferences prefs =
          await SharedPreferences.getInstance();
      final String key = 'resource_rate_counted_$docId';

      if (prefs.getBool(key) ?? false) {
        if (mounted) {
          setState(() => ratedDocs.add(docId));
        }
        return;
      }

      final DocumentSnapshot doc =
          await _firestore.collection('resources').doc(docId).get();

      final dynamic rawData = doc.data();
      final Map<String, dynamic> data =
          rawData is Map ? Map<String, dynamic>.from(rawData) : {};

      final double currentRating = data['rating'] is num
          ? (data['rating'] as num).toDouble()
          : double.tryParse(data['rating']?.toString() ?? '') ?? 0.0;
      final int ratingCount = data['ratingCount'] is num
          ? (data['ratingCount'] as num).toInt()
          : int.tryParse(data['ratingCount']?.toString() ?? '') ?? 0;

      final double newRating =
          ((currentRating * ratingCount) + rating) / (ratingCount + 1);

      await _firestore.collection('resources').doc(docId).update({
        'rating': newRating,
        'ratingCount': FieldValue.increment(1),
      });

      await prefs.setBool(key, true);
      final List<String> savedRatings =
          prefs.getStringList('rated_resources') ?? [];
      if (!savedRatings.contains(docId)) {
        savedRatings.add(docId);
        await prefs.setStringList('rated_resources', savedRatings);
      }

      if (!mounted) return;
      setState(() => ratedDocs.add(docId));
    } catch (e) {
      debugPrint('Rating error: $e');
    } finally {
      _rateInProgress.remove(docId);
    }
  }

  // ---------------------------------------------------------------------------
  // ADMIN ACCESS
  // ---------------------------------------------------------------------------
  void _handleHeaderTap() {
    final DateTime now = DateTime.now();
    if (_lastTapTime == null ||
        now.difference(_lastTapTime!) >
            const Duration(seconds: 2)) {
      _tapCount = 1;
    } else {
      _tapCount++;
    }
    _lastTapTime = now;
    if (_tapCount >= 5) {
      _tapCount = 0;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const AdminDashboard(),
        ),
      );
      _showToast(success: true);
    }
  }
  // ---------------------------------------------------------------------------
  // GEMINI
  // ---------------------------------------------------------------------------
  void _showGeminiChat() {
    final GenerativeModel? aiModel = model;
    if (aiModel == null) {
      _showToast(success: false);
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _GeminiChatSheet(model: aiModel),
      ),
    );
  }
  void _showFlashcards(String subject) {
    final GenerativeModel? aiModel = model;
    if (aiModel == null) {
      _showToast(success: false);
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FlashcardDialog(
          subject: subject,
          model: aiModel,
        ),
      ),
    );
  }
  // ---------------------------------------------------------------------------
  // FORMATTING HELPERS
  // ---------------------------------------------------------------------------
  String _formatDate(dynamic timestamp) {
    try {
      DateTime? date;
      if (timestamp is Timestamp) {
        date = timestamp.toDate();
      } else if (timestamp is DateTime) {
        date = timestamp;
      }
      if (date == null) {
        return '';
      }
      return DateFormat(
        'dd MMM yyyy, hh:mm a',
      ).format(date);
    } catch (e) {
      return '';
    }
  }
  String _formatBytes(dynamic value) {
    int bytes = 0;
    if (value is num) {
      bytes = value.toInt();
    } else {
      bytes = int.tryParse(
            value?.toString() ?? '',
          ) ??
          0;
    }
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1048576) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1073741824) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
  }
  Color _getCardColor(String course) {
    final int index =
        course.hashCode % _cardColors.length;
    return _cardColors[index.abs()];
  }
  IconData _getFileIcon(String url) {
    final String lower =
        url.toLowerCase();
    if (lower.contains('.pdf')) {
      return Icons.picture_as_pdf;
    }
    if (lower.contains('.jpg') ||
        lower.contains('.jpeg') ||
        lower.contains('.png') ||
        lower.contains('.gif') ||
        lower.contains('.webp')) {
      return Icons.image;
    }
    if (lower.contains('.mp4') ||
        lower.contains('.mov') ||
        lower.contains('.avi')) {
      return Icons.video_file;
    }
    if (lower.contains('.doc') ||
        lower.contains('.docx')) {
      return Icons.description;
    }
    if (lower.contains('.xls') ||
        lower.contains('.xlsx')) {
      return Icons.table_chart;
    }
    if (lower.contains('.ppt') ||
        lower.contains('.pptx')) {
      return Icons.slideshow;
    }
    return Icons.insert_drive_file;
  }
  // ---------------------------------------------------------------------------
  // MY UPLOADS VIEW
  // -----------------------------------------------------------------------------
  Widget _buildMyUploadsView(
    List<QueryDocumentSnapshot> approvedDocs,
    Color primaryGreen,
  ) {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('resources_pending')
          .orderBy(
            'uploadedAt',
            descending: true,
          )
          .snapshots(),
      builder: (context, pendingSnap) {
        final List<_MyUploadItem> uploads = [];
        // APPROVED RESOURCES
        for (final QueryDocumentSnapshot doc
            in approvedDocs) {
          if (_isMyUpload(doc)) {
            uploads.add(
              _MyUploadItem(
                document: doc,
                isPendingCollection: false,
              ),
            );
          }
        }
        // PENDING / REJECTED RESOURCES
        if (pendingSnap.hasData) {
          for (final QueryDocumentSnapshot doc
              in pendingSnap.data!.docs) {
            if (_isMyUpload(doc)) {
              uploads.add(
                _MyUploadItem(
                  document: doc,
                  isPendingCollection: true,
                ),
              );
            }
          }
        }
        // Remove duplicate documents.
        final Set<String> seenKeys = {};
        uploads.removeWhere((item) {
          final String key =
              '${item.isPendingCollection ? 'pending' : 'approved'}_${item.document.id}';
          if (seenKeys.contains(key)) {
            return true;
          }
          seenKeys.add(key);
          return false;
        });
        // Sort newest first.
        uploads.sort((a, b) {
          final dynamic aData = a.document.data();
          final dynamic bData = b.document.data();
          DateTime? aDate;
          DateTime? bDate;
          if (aData is Map &&
              aData['uploadedAt'] is Timestamp) {
            aDate =
                (aData['uploadedAt'] as Timestamp).toDate();
          }
          if (bData is Map &&
              bData['uploadedAt'] is Timestamp) {
            bDate =
                (bData['uploadedAt'] as Timestamp).toDate();
          }
          if (aDate == null && bDate == null) {
            return 0;
          }
          if (aDate == null) {
            return 1;
          }
          if (bDate == null) {
            return -1;
          }
          return bDate.compareTo(aDate);
        });
        if (uploads.isEmpty) {
          return Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment:
                    MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.cloud_upload,
                    size: 80,
                    color: Colors.grey.shade400,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No uploads yet',
                    style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Files you upload will appear here.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              const StudentUploadScreen(),
                        ),
                      );
                    },
                    icon: const Icon(
                      Icons.upload_file,
                    ),
                    label: const Text(
                      'Upload a File',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          primaryGreen,
                      foregroundColor:
                          Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: myUploads.isEmpty
                        ? null
                        : _clearUploadHistory,
                    icon: const Icon(
                      Icons.delete_outline,
                    ),
                    label: const Text(
                      'Clear History',
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'My Uploads (${uploads.length})',
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _clearUploadHistory,
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                    ),
                    label: const Text('Clear'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(
                  bottom: 90,
                ),
                itemCount: uploads.length,
                itemBuilder: (context, index) {
                  final _MyUploadItem item =
                      uploads[index];
                  final QueryDocumentSnapshot doc =
                      item.document;
                  final dynamic rawData =
                      doc.data();
                  if (rawData is! Map) {
                    return const SizedBox.shrink();
                  }
                  final Map<String, dynamic> data =
                      Map<String, dynamic>.from(
                    rawData,
                  );
                  final String status =
                      _getUploadStatus(
                    doc,
                    isPendingCollection:
                        item.isPendingCollection,
                  );
                  final Color statusColor =
                      _getStatusColor(status);
                  final String title =
                      data['title']?.toString() ??
                          data['fileName']?.toString() ??
                          'Uploaded File';
                  final String fileUrl =
                      data['fileUrl']?.toString() ??
                          data['url']?.toString() ??
                          '';
                  final String course =
                      data['course']?.toString() ??
                          'Unknown Subject';
                  final String examType =
                      data['examType']?.toString() ??
                          'Resource';
                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(14),
                    ),
                    child: Padding(
                      padding:
                          const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding:
                                    const EdgeInsets.all(
                                  10,
                                ),
                                decoration:
                                    BoxDecoration(
                                  color: statusColor
                                      .withOpacity(
                                    0.12,
                                  ),
                                  borderRadius:
                                      BorderRadius
                                          .circular(
                                    12,
                                  ),
                                ),
                                child: Icon(
                                  _getFileIcon(
                                    fileUrl,
                                  ),
                                  color:
                                      statusColor,
                                  size: 28,
                                ),
                              ),
                              const SizedBox(
                                width: 12,
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment
                                          .start,
                                  children: [
                                    Text(
                                      title,
                                      maxLines: 2,
                                      overflow:
                                          TextOverflow
                                              .ellipsis,
                                      style:
                                          GoogleFonts
                                              .poppins(
                                        fontWeight:
                                            FontWeight
                                                .w600,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(
                                      height: 5,
                                    ),
                                    Text(
                                      '$course • $examType',
                                      maxLines: 2,
                                      overflow:
                                          TextOverflow
                                              .ellipsis,
                                      style:
                                          GoogleFonts
                                              .poppins(
                                        fontSize: 12,
                                        color:
                                            Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(
                            height: 10,
                          ),
                          // STATUS TAG
                          Row(
                            children: [
                              Container(
                                padding:
                                    const EdgeInsets
                                        .symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration:
                                    BoxDecoration(
                                  color: statusColor
                                      .withOpacity(
                                    0.12,
                                  ),
                                  borderRadius:
                                      BorderRadius
                                          .circular(
                                    20,
                                  ),
                                  border: Border.all(
                                    color: statusColor
                                        .withOpacity(
                                      0.35,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize:
                                      MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _getStatusIcon(
                                        status,
                                      ),
                                      size: 15,
                                      color:
                                          statusColor,
                                    ),
                                    const SizedBox(
                                      width: 5,
                                    ),
                                    Text(
                                      status,
                                      style:
                                          GoogleFonts
                                              .poppins(
                                        color:
                                            statusColor,
                                        fontSize: 11,
                                        fontWeight:
                                            FontWeight
                                                .w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Spacer(),
                              if (fileUrl.isNotEmpty)
                                IconButton(
                                  tooltip:
                                      'Open file',
                                  icon: Icon(
                                    Icons
                                        .open_in_new,
                                    color:
                                        primaryGreen,
                                  ),
                                  onPressed: () =>
                                      _openResource(
                                    doc.id,
                                    fileUrl,
                                    title,
                                    countDownload: false,
                                  ),
                                ),
                            ],
                          ),
                          const Divider(
                            height: 18,
                          ),
                          Row(
                            children: [
                              const Icon(
                                Icons
                                    .calendar_today,
                                size: 13,
                                color: Colors.grey,
                              ),
                              const SizedBox(
                                width: 5,
                              ),
                              Expanded(
                                child: Text(
                                  _formatDate(
                                    data[
                                        'uploadedAt'],
                                  ),
                                  style:
                                      GoogleFonts
                                          .poppins(
                                    fontSize: 10,
                                    color:
                                        Colors.grey,
                                  ),
                                ),
                              ),
                              if (data[
                                      'fileSize'] !=
                                  null) ...[
                                const Icon(
                                  Icons.data_object,
                                  size: 13,
                                  color: Colors.grey,
                                ),
                                const SizedBox(
                                  width: 5,
                                ),
                                Text(
                                  _formatBytes(
                                    data[
                                        'fileSize'],
                                  ),
                                  style:
                                      GoogleFonts
                                          .poppins(
                                    fontSize: 10,
                                    color:
                                        Colors.grey,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
  // ---------------------------------------------------------------------------
  // MAIN BUILD
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    const Color primaryGreen =
        Color(0xFF00C896);
    const Color secondaryBlue =
        Color(0xFF3B82F6);
    final bool isDark =
        _themeMode == 'dark';
    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore
          .collection('settings')
          .doc('app')
          .snapshots(),
      builder: (
        context,
        settingsSnap,
      ) {
        List<String> liveSubjects = [
          'All',
          'Maths',
          'Physics',
          'Chemistry',
          'Biology',
          'Favorites',
          'Recent',
          'My Uploads',
        ];
        if (settingsSnap.hasData &&
            settingsSnap.data!.exists) {
          final dynamic rawSettings =
              settingsSnap.data!.data();
          if (rawSettings is Map) {
            final dynamic rawSubjects =
                rawSettings['subjects'];
            if (rawSubjects is List) {
              final List<String> dbSubjects =
                  rawSubjects
                      .map(
                        (e) => e.toString(),
                      )
                      .where(
                        (e) => e.isNotEmpty,
                      )
                      .toList();
              liveSubjects = [
                'All',
                ...dbSubjects,
                'Favorites',
                'Recent',
                'My Uploads',
              ];
            }
          }
        }
        if (!liveSubjects.contains(
          selectedCourse,
        )) {
          selectedCourse = 'All';
        }
        return Theme(
          data: ThemeData(
            brightness: isDark
                ? Brightness.dark
                : Brightness.light,
            primaryColor: primaryGreen,
            scaffoldBackgroundColor:
                isDark
                    ? const Color(0xFF121212)
                    : Colors.grey.shade50,
            cardColor: isDark
                ? const Color(0xFF1E1E1E)
                : Colors.white,
            colorScheme:
                ColorScheme.fromSeed(
              seedColor: primaryGreen,
              brightness: isDark
                  ? Brightness.dark
                  : Brightness.light,
            ),
          ),
          child: Scaffold(
            appBar: AppBar(
              title: GestureDetector(
                onTap: _handleHeaderTap,
                child: Text(
                  'ExamHook',
                  style: GoogleFonts.poppins(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
              backgroundColor: primaryGreen,
              elevation: 0,
              actions: [
                // AI BUTTON REMAINS
                IconButton(
                  tooltip: 'Ask AI',
                  icon: const Icon(
                    Icons.smart_toy,
                  ),
                  onPressed:
                      _showGeminiChat,
                ),
                // UPLOAD APPBAR BUTTON REMOVED
                IconButton(
                  tooltip: 'Request Notes',
                  icon: const Icon(
                    Icons.mail_outline,
                  ),
                  onPressed:
                      _showRequestDialog,
                ),
              ],
            ),
            // -----------------------------------------------------------------
            // DRAWER
            // -----------------------------------------------------------------
            drawer: Drawer(
              child: Column(
                children: [
                  DrawerHeader(
                    decoration:
                        const BoxDecoration(
                      color: Color(0xFF1E293B),
                    ),
                    child: Column(
                      mainAxisAlignment:
                          MainAxisAlignment.center,
                      children: [
                        GestureDetector(
                          onTap:
                              _handleHeaderTap,
                          child:
                              const Icon(
                            Icons.school,
                            size: 60,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(
                          height: 10,
                        ),
                        Text(
                          'ExamHook',
                          style:
                              GoogleFonts.poppins(
                            color:
                                Colors.white,
                            fontSize: 22,
                            fontWeight:
                                FontWeight
                                    .bold,
                          ),
                        ),
                        Text(
                          'AI + Resources',
                          style:
                              GoogleFonts.poppins(
                            color:
                                Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment
                              .start,
                      children: [
                        Text(
                          'Theme',
                          style:
                              GoogleFonts.poppins(
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                        const SizedBox(
                          height: 8,
                        ),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                              value: 'light',
                              label:
                                  Text('Light'),
                              icon: Icon(
                                Icons.light_mode,
                              ),
                            ),
                            ButtonSegment(
                              value: 'dark',
                              label:
                                  Text('Dark'),
                              icon: Icon(
                                Icons.dark_mode,
                              ),
                            ),
                          ],
                          selected: {
                            _themeMode,
                          },
                          onSelectionChanged:
                              (newSelection) {
                            if (newSelection
                                .isNotEmpty) {
                              _saveTheme(
                                newSelection
                                    .first,
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
                  // AI
                  ListTile(
                    leading: const Icon(
                      Icons.smart_toy,
                      color:
                          primaryGreen,
                    ),
                    title: Text(
                      'Ask ExamHook AI',
                      style:
                          GoogleFonts.poppins(),
                    ),
                    onTap: () {
                      Navigator.pop(
                        context,
                      );
                      _showGeminiChat();
                    },
                  ),
                  // FLASHCARDS
                  ListTile(
                    leading: const Icon(
                      Icons.quiz,
                      color:
                          primaryGreen,
                    ),
                    title: Text(
                      'AI Flashcards',
                      style:
                          GoogleFonts.poppins(),
                    ),
                    onTap: () {
                      Navigator.pop(
                        context,
                      );
                      _showFlashcards(
                        'General Knowledge',
                      );
                    },
                  ),
                  // DRAWER UPLOAD OPTION REMOVED
                  Expanded(
                    child:
                        ListView.builder(
                      itemCount:
                          liveSubjects.length,
                      itemBuilder:
                          (context, index) {
                        final String subject =
                            liveSubjects[
                                index];
                        IconData icon =
                            Icons.book;
                        if (subject ==
                            'Favorites') {
                          icon =
                              Icons.bookmark;
                        }
                        if (subject ==
                            'Recent') {
                          icon =
                              Icons.history;
                        }
                        if (subject ==
                            'My Uploads') {
                          icon =
                              Icons.cloud_upload;
                        }
                        final bool isNormalSubject =
                            subject !=
                                'All' &&
                            subject !=
                                'Favorites' &&
                            subject !=
                                'Recent' &&
                            subject !=
                                'My Uploads';
                        return ListTile(
                          leading: Icon(
                            icon,
                            color:
                                primaryGreen,
                          ),
                          title: Text(
                            subject,
                            style:
                                GoogleFonts.poppins(),
                          ),
                          trailing:
                              isNormalSubject
                                  ? IconButton(
                                      icon:
                                          const Icon(
                                        Icons.quiz,
                                        size: 18,
                                      ),
                                      onPressed:
                                          () =>
                                              _showFlashcards(
                                        subject,
                                      ),
                                    )
                                  : null,
                          selected:
                              selectedCourse ==
                                  subject,
                          selectedTileColor:
                              primaryGreen
                                  .withOpacity(
                            0.1,
                          ),
                          onTap: () {
                            setState(() {
                              selectedCourse =
                                  subject;
                            });
                            Navigator.pop(
                              context,
                            );
                          },
                        );
                      },
                    ),
                  ),
                  ListTile(
                    leading: const Icon(
                      Icons.description,
                      color:
                          primaryGreen,
                    ),
                    title: Text(
                      'Terms & Conditions',
                      style:
                          GoogleFonts.poppins(),
                    ),
                    onTap:
                        _showTermsDialog,
                  ),
                ],
              ),
            ),
            // -----------------------------------------------------------------
            // FAB - ONLY UPLOAD METHOD
            // -----------------------------------------------------------------
            floatingActionButton:
                FloatingActionButton.extended(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const StudentUploadScreen(),
                  ),
                );
              },
              backgroundColor:
                  primaryGreen,
              icon: const Icon(
                Icons.add,
              ),
              label: Text(
                'Upload',
                style:
                    GoogleFonts.poppins(
                  fontWeight:
                      FontWeight.w600,
                ),
              ),
            ),
            // -----------------------------------------------------------------
            // BODY
            // -----------------------------------------------------------------
            body: Column(
              children: [
                _buildDailyQuotesMarquee(isDark),
                Padding(
                  padding:
                      const EdgeInsets.all(
                    12,
                  ),
                  child: TextField(
                    controller:
                        _searchController,
                    decoration:
                        InputDecoration(
                      hintText:
                          'Search resources...',
                      prefixIcon:
                          const Icon(
                        Icons.search,
                      ),
                      border:
                          OutlineInputBorder(
                        borderRadius:
                            BorderRadius
                                .circular(
                          12,
                        ),
                      ),
                      filled: true,
                      fillColor: isDark
                          ? Colors.grey
                              .shade800
                          : Colors.grey
                              .shade100,
                    ),
                    onChanged: (val) {
                      setState(() {
                        searchQuery =
                            val
                                .toLowerCase()
                                .trim();
                      });
                    },
                  ),
                ),
                if (selectedCourse !=
                    'My Uploads')
                  Padding(
                    padding:
                        const EdgeInsets
                            .symmetric(
                      horizontal: 12,
                    ),
                    child:
                        DropdownButtonFormField<
                            String>(
                      value:
                          selectedCourse,
                      decoration:
                          InputDecoration(
                        labelText:
                            'Subject',
                        border:
                            OutlineInputBorder(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            12,
                          ),
                        ),
                      ),
                      items: liveSubjects
                          .map(
                            (
                              e,
                            ) =>
                                DropdownMenuItem<
                                    String>(
                              value: e,
                              child:
                                  Text(e),
                            ),
                          )
                          .toList(),
                      onChanged:
                          (val) {
                        if (val ==
                            null) {
                          return;
                        }
                        setState(() {
                          selectedCourse =
                              val;
                        });
                      },
                    ),
                  ),
                const SizedBox(
                  height: 10,
                ),
                Expanded(
                  child:
                      StreamBuilder<
                          QuerySnapshot>(
                    stream: _firestore
                        .collection(
                            'resources')
                        .orderBy(
                          'uploadedAt',
                          descending:
                              true,
                        )
                        .snapshots(),
                    builder: (
                      context,
                      snapshot,
                    ) {
                      if (snapshot
                              .connectionState ==
                          ConnectionState
                              .waiting) {
                        return const Center(
                          child:
                              CircularProgressIndicator(),
                        );
                      }
                      if (snapshot.hasError) {
                        return Center(
                          child:
                              Padding(
                            padding:
                                const EdgeInsets
                                    .all(
                              20,
                            ),
                            child: Text(
                              'Error: ${snapshot.error}',
                            ),
                          ),
                        );
                      }
                      final List<
                              QueryDocumentSnapshot>
                          allApprovedDocs =
                          snapshot.hasData
                              ? snapshot
                                  .data!
                                  .docs
                              : [];
                      // -------------------------------------------------------
                      // MY UPLOADS
                      // -------------------------------------------------------
                      if (selectedCourse ==
                          'My Uploads') {
                        return _buildMyUploadsView(
                          allApprovedDocs,
                          primaryGreen,
                        );
                      }
                      // -------------------------------------------------------
                      // NORMAL RESOURCES
                      // -------------------------------------------------------
                      List<
                              QueryDocumentSnapshot>
                          docs =
                          List.from(
                        allApprovedDocs,
                      );
                      if (selectedCourse ==
                          'Favorites') {
                        docs = docs
                            .where(
                              (d) =>
                                  favoriteDocs
                                      .contains(
                                d.id,
                              ),
                            )
                            .toList();
                      } else if (selectedCourse ==
                          'Recent') {
                        docs = docs
                            .where(
                              (d) =>
                                  recentlyViewed
                                      .contains(
                                d.id,
                              ),
                            )
                            .toList();
                      } else if (selectedCourse !=
                          'All') {
                        docs = docs
                            .where(
                              (d) {
                                final dynamic raw =
                                    d.data();
                                if (raw is! Map) {
                                  return false;
                                }
                                return raw[
                                            'course']
                                        ?.toString() ==
                                    selectedCourse;
                              },
                            )
                            .toList();
                      }
                      if (searchQuery
                          .isNotEmpty) {
                        docs = docs
                            .where(
                              (d) {
                                final dynamic raw =
                                    d.data();
                                if (raw is! Map) {
                                  return false;
                                }
                                final Map<String,
                                        dynamic>
                                    data =
                                    Map<String,
                                        dynamic>.from(
                                  raw,
                                );
                                final String title =
                                    data[
                                                'title']
                                            ?.toString()
                                            .toLowerCase() ??
                                        '';
                                final String course =
                                    data[
                                                'course']
                                            ?.toString()
                                            .toLowerCase() ??
                                        '';
                                final String fileName =
                                    data[
                                                'fileName']
                                            ?.toString()
                                            .toLowerCase() ??
                                        '';
                                return title.contains(
                                      searchQuery,
                                    ) ||
                                    course.contains(
                                      searchQuery,
                                    ) ||
                                    fileName.contains(
                                      searchQuery,
                                    );
                              },
                            )
                            .toList();
                      }
                      if (docs.isEmpty) {
                        return Center(
                          child:
                              Padding(
                            padding:
                                const EdgeInsets
                                    .all(
                              24,
                            ),
                            child:
                                Column(
                              mainAxisAlignment:
                                  MainAxisAlignment
                                      .center,
                              children: [
                                Icon(
                                  Icons
                                      .folder_open,
                                  size: 100,
                                  color:
                                      primaryGreen
                                          .withOpacity(
                                    0.5,
                                  ),
                                ),
                                const SizedBox(
                                  height: 20,
                                ),
                                Text(
                                  'No resources yet',
                                  style:
                                      GoogleFonts
                                          .poppins(
                                    fontSize:
                                        22,
                                    fontWeight:
                                        FontWeight
                                            .bold,
                                  ),
                                ),
                                const SizedBox(
                                  height: 8,
                                ),
                                Text(
                                  'Be the first to upload or ask AI',
                                  textAlign:
                                      TextAlign
                                          .center,
                                  style:
                                      GoogleFonts
                                          .poppins(
                                    fontSize:
                                        14,
                                    color:
                                        Colors
                                            .grey,
                                  ),
                                ),
                                const SizedBox(
                                  height: 20,
                                ),
                                ElevatedButton
                                    .icon(
                                  onPressed:
                                      _showGeminiChat,
                                  icon:
                                      const Icon(
                                    Icons
                                        .smart_toy,
                                  ),
                                  label:
                                      const Text(
                                    'Ask AI',
                                  ),
                                  style:
                                      ElevatedButton
                                          .styleFrom(
                                    backgroundColor:
                                        primaryGreen,
                                    foregroundColor:
                                        Colors
                                            .white,
                                    shape:
                                        RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius
                                              .circular(
                                        12,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                      // -------------------------------------------------------
                      // RESOURCE LIST
                      // -------------------------------------------------------
                      return ListView.builder(
                        padding:
                            const EdgeInsets
                                .only(
                          bottom: 90,
                        ),
                        itemCount:
                            docs.length,
                        itemBuilder:
                            (context, index) {
                          final QueryDocumentSnapshot
                              doc =
                              docs[index];
                          final dynamic raw =
                              doc.data();
                          if (raw is! Map) {
                            return const SizedBox
                                .shrink();
                          }
                          final Map<String,
                                  dynamic>
                              data =
                              Map<String,
                                  dynamic>.from(
                            raw,
                          );
                          final String docId =
                              doc.id;
                          final String title =
                              data['title']
                                      ?.toString() ??
                                  'No Title';
                          final String fileUrl =
                              data['fileUrl']
                                      ?.toString() ??
                                  '';
                          final String course =
                              data['course']
                                      ?.toString() ??
                                  '';
                          final String examType =
                              data['examType']
                                      ?.toString() ??
                                  '';
                          final bool isLiked =
                              likedDocs
                                  .contains(
                            docId,
                          );
                          final bool isRated =
                              ratedDocs
                                  .contains(
                            docId,
                          );
                          final bool isFav =
                              favoriteDocs
                                  .contains(
                            docId,
                          );
                          final Color cardColor =
                              _getCardColor(
                            course,
                          );
                          return Card(
                            margin:
                                const EdgeInsets
                                    .symmetric(
                              horizontal:
                                  12,
                              vertical:
                                  8,
                            ),
                            elevation: 4,
                            shape:
                                RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius
                                      .circular(
                                20,
                              ),
                            ),
                            child:
                                Container(
                              decoration:
                                  BoxDecoration(
                                borderRadius:
                                    BorderRadius
                                        .circular(
                                  20,
                                ),
                                gradient:
                                    LinearGradient(
                                  colors: [
                                    cardColor
                                        .withOpacity(
                                      0.1,
                                    ),
                                    cardColor
                                        .withOpacity(
                                      0.02,
                                    ),
                                  ],
                                  begin:
                                      Alignment
                                          .topLeft,
                                  end:
                                      Alignment
                                          .bottomRight,
                                ),
                                border:
                                    Border.all(
                                  color: cardColor
                                      .withOpacity(
                                    0.3,
                                  ),
                                ),
                              ),
                              child:
                                  Padding(
                                padding:
                                    const EdgeInsets
                                        .all(
                                  14,
                                ),
                                child:
                                    Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment
                                          .start,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment
                                              .start,
                                      children: [
                                        Container(
                                          padding:
                                              const EdgeInsets
                                                  .all(
                                            10,
                                          ),
                                          decoration:
                                              BoxDecoration(
                                            color: cardColor
                                                .withOpacity(
                                              0.2,
                                            ),
                                            borderRadius:
                                                BorderRadius
                                                    .circular(
                                              12,
                                            ),
                                          ),
                                          child:
                                              Icon(
                                            _getFileIcon(
                                              fileUrl,
                                            ),
                                            color:
                                                cardColor,
                                            size:
                                                28,
                                          ),
                                        ),
                                        const SizedBox(
                                          width:
                                              12,
                                        ),
                                        Expanded(
                                          child:
                                              Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment
                                                    .start,
                                            children: [
                                              Text(
                                                title,
                                                style:
                                                    GoogleFonts.poppins(
                                                  fontWeight:
                                                      FontWeight.w600,
                                                  fontSize:
                                                      16,
                                                ),
                                              ),
                                              const SizedBox(
                                                height:
                                                    4,
                                              ),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal:
                                                      8,
                                                  vertical:
                                                      2,
                                                ),
                                                decoration:
                                                    BoxDecoration(
                                                  color:
                                                      cardColor,
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                    8,
                                                  ),
                                                ),
                                                child:
                                                    Text(
                                                  '$course • $examType',
                                                  style:
                                                      GoogleFonts.poppins(
                                                    fontSize:
                                                        11,
                                                    color:
                                                        Colors.white,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          icon:
                                              Icon(
                                            isFav
                                                ? Icons.bookmark
                                                : Icons.bookmark_border,
                                            color:
                                                primaryGreen,
                                          ),
                                          onPressed:
                                              () =>
                                                  _toggleFavorite(
                                            docId,
                                          ),
                                        ),
                                        IconButton(
                                          icon:
                                              const Icon(
                                            Icons.share,
                                            color:
                                                Colors.grey,
                                            size:
                                                24,
                                          ),
                                          onPressed:
                                              () =>
                                                  _shareResource(
                                            title,
                                            fileUrl,
                                          ),
                                        ),
                                        if (fileUrl
                                            .toLowerCase()
                                            .contains(
                                              '.pdf',
                                            ))
                                          IconButton(
                                            icon:
                                                Icon(
                                              Icons.quiz,
                                              color:
                                                  primaryGreen,
                                            ),
                                            tooltip:
                                                'Generate Flashcards',
                                            onPressed:
                                                () =>
                                                    _generateFlashcardsFromPdf(
                                              fileUrl,
                                              title,
                                            ),
                                          ),
                                        IconButton(
                                          icon:
                                              const Icon(
                                            Icons.open_in_new,
                                            color:
                                                secondaryBlue,
                                            size:
                                                28,
                                          ),
                                          onPressed:
                                              () =>
                                                  _openResource(
                                            docId,
                                            fileUrl,
                                            title,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(
                                      height:
                                          10,
                                    ),
                                    Row(
                                      children: [
                                        const Icon(
                                          Icons
                                              .calendar_today,
                                          size:
                                              12,
                                          color:
                                              Colors.grey,
                                        ),
                                        const SizedBox(
                                          width:
                                              4,
                                        ),
                                        Text(
                                          _formatDate(
                                            data[
                                                'uploadedAt'],
                                          ),
                                          style:
                                              GoogleFonts.poppins(
                                            fontSize:
                                                11,
                                          ),
                                        ),
                                        const SizedBox(
                                          width:
                                              12,
                                        ),
                                        const Icon(
                                          Icons
                                              .data_object,
                                          size:
                                              12,
                                          color:
                                              Colors.grey,
                                        ),
                                        const SizedBox(
                                          width:
                                              4,
                                        ),
                                        Text(
                                          _formatBytes(
                                            data[
                                                'fileSize'],
                                          ),
                                          style:
                                              GoogleFonts.poppins(
                                            fontSize:
                                                11,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(
                                      height:
                                          10,
                                    ),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment
                                              .spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            IconButton(
                                              icon:
                                                  Icon(
                                                Icons.favorite,
                                                color:
                                                    isLiked
                                                        ? Colors.red
                                                        : Colors.grey,
                                                size:
                                                    20,
                                              ),
                                              tooltip: isLiked
                                                  ? 'Already liked'
                                                  : 'Like resource',
                                              onPressed: isLiked
                                                  ? null
                                                  : () => _likeResource(
                                                      docId,
                                                    ),
                                            ),
                                            Text(
                                              '${data['likes'] ?? 0}',
                                              style:
                                                  GoogleFonts.poppins(
                                                fontSize:
                                                    12,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Row(
                                          children: [
                                            const Icon(
                                              Icons.star,
                                              color:
                                                  Colors.amber,
                                              size:
                                                  20,
                                            ),
                                            Text(
                                              ' ${(data['rating'] is num ? (data['rating'] as num).toDouble() : 0.0).toStringAsFixed(1)}',
                                              style:
                                                  GoogleFonts.poppins(
                                                fontSize:
                                                    12,
                                              ),
                                            ),
                                            PopupMenuButton<
                                                double>(
                                              enabled:
                                                  !isRated,
                                              onSelected:
                                                  (val) =>
                                                      _rateResource(
                                                docId,
                                                val,
                                              ),
                                              itemBuilder:
                                                  (context) =>
                                                      [
                                                1.0,
                                                2.0,
                                                3.0,
                                                4.0,
                                                5.0,
                                              ]
                                                          .map(
                                                            (
                                                              e,
                                                            ) =>
                                                                PopupMenuItem<double>(
                                                              value:
                                                                  e,
                                                              child:
                                                                  Text(
                                                                '${e.toInt()} Star',
                                                              ),
                                                            ),
                                                          )
                                                          .toList(),
                                              child:
                                                  Icon(
                                                Icons.rate_review,
                                                size:
                                                    20,
                                                color:
                                                    isRated
                                                        ? Colors.grey
                                                        : Colors.black,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Row(
                                          children: [
                                            const Icon(
                                              Icons.download,
                                              color:
                                                  Colors.blue,
                                              size:
                                                  20,
                                            ),
                                            Text(
                                              ' ${data['downloads'] ?? 0}',
                                              style:
                                                  GoogleFonts.poppins(
                                                fontSize:
                                                    12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
// -----------------------------------------------------------------------------
// MY UPLOAD ITEM
// -----------------------------------------------------------------------------
class _MyUploadItem {
  final QueryDocumentSnapshot document;
  final bool isPendingCollection;
  const _MyUploadItem({
    required this.document,
    required this.isPendingCollection,
  });
}
// -----------------------------------------------------------------------------
// FLASHCARD DIALOG
// -----------------------------------------------------------------------------
class _FlashcardDialog extends StatefulWidget {
  final String subject;
  final GenerativeModel model;
  const _FlashcardDialog({super.key, required this.subject, required this.model});

  @override
  State<_FlashcardDialog> createState() => _FlashcardDialogState();
}

class _FlashcardDialogState extends State<_FlashcardDialog> {
  List<Flashcard> _cards = [];
  bool _isLoading = true;
  int _index = 0;
  int? _selectedOption;

  void _toast(bool success) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        left: 24,
        right: 24,
        bottom: 30,
        child: Material(
          color: Colors.transparent,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              decoration: BoxDecoration(
                color: success ? Colors.green.shade600 : Colors.red.shade600,
                borderRadius: BorderRadius.circular(28),
              ),
              child: Text(
                success ? 'Successful!' : 'Something went wrong!',
                style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 2), () {
      if (entry.mounted) entry.remove();
    });
  }

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    try {
      final String prompt = '''
Generate 20 multiple-choice flashcards for ${widget.subject} for high school exams.
Rules:
1. Return ONLY a valid JSON array. No markdown, no asterisks, no explanation.
2. Format: [{"q":"question","a":"correct answer","options":["option 1","option 2","option 3","option 4"],"correctIndex":0}]
3. Every card MUST have exactly 4 distinct options.
4. One option MUST exactly match the correct answer in "a".
5. correctIndex is the zero-based index of that correct option.
6. For formulas write them in plain LaTeX without \$ signs. Example: F = ma, E = mc^2, \\\\frac{a}{b}, x^2
7. Keep answers short, max 15 words.
''';
      final response = await widget.model.generateContent([Content.text(prompt)]);
      var text = response.text ?? '';
      text = text.replaceAll('```json', '').replaceAll('```', '').trim();
      final decoded = jsonDecode(text);
      if (decoded is! List) throw Exception('Invalid AI response');

      final cards = decoded.whereType<Map>().map((e) {
        final options = e['options'] is List
            ? List<String>.from((e['options'] as List).map((v) => v.toString()))
            : <String>[];
        return Flashcard(
          question: e['q']?.toString() ?? '',
          answer: e['a']?.toString() ?? '',
          options: options,
          correctIndex: e['correctIndex'] is int
              ? e['correctIndex'] as int
              : int.tryParse(e['correctIndex']?.toString() ?? '') ?? 0,
        );
      }).where((card) =>
          card.question.isNotEmpty &&
          card.answer.isNotEmpty &&
          card.options.length == 4 &&
          card.correctIndex >= 0 &&
          card.correctIndex < 4).toList();

      if (!mounted) return;
      setState(() {
        _cards = cards;
        _isLoading = false;
      });
      if (cards.isEmpty) _toast(false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _toast(false);
    }
  }

  void _selectOption(int option) {
    if (_selectedOption != null) return;
    final card = _cards[_index];
    setState(() => _selectedOption = option);
    _toast(option == card.correctIndex);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.subject} Flashcards', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        backgroundColor: const Color(0xFF00C896),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _cards.isEmpty
              ? Center(child: Text('Could not generate flashcards.', style: GoogleFonts.poppins()))
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        LinearProgressIndicator(
                          value: (_index + 1) / _cards.length,
                          minHeight: 7,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        const SizedBox(height: 16),
                        Text('Question ${_index + 1} of ${_cards.length}',
                            style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 12),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Card(
                                  elevation: 3,
                                  child: Padding(
                                    padding: const EdgeInsets.all(22),
                                    child: _buildMathText(
                                      _cards[_index].question,
                                      style: GoogleFonts.poppins(fontSize: 21, fontWeight: FontWeight.w600),
                                      align: TextAlign.center,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                ...List.generate(4, (i) {
                                  final card = _cards[_index];
                                  final selected = _selectedOption == i;
                                  final correct = i == card.correctIndex;
                                  Color? fill;
                                  Color border = Theme.of(context).colorScheme.outline;
                                  if (_selectedOption != null) {
                                    if (correct) {
                                      fill = Colors.green.shade100;
                                      border = Colors.green;
                                    } else if (selected) {
                                      fill = Colors.red.shade100;
                                      border = Colors.red;
                                    }
                                  }
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: InkWell(
                                      onTap: () => _selectOption(i),
                                      borderRadius: BorderRadius.circular(14),
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 180),
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: fill,
                                          border: Border.all(color: border, width: 2),
                                          borderRadius: BorderRadius.circular(14),
                                        ),
                                        child: Row(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            CircleAvatar(radius: 15, child: Text(String.fromCharCode(65 + i))),
                                            const SizedBox(width: 12),
                                            Expanded(child: _buildMathText(card.options[i], style: GoogleFonts.poppins(fontSize: 16))),
                                            if (_selectedOption != null && correct)
                                              const Icon(Icons.check_circle, color: Colors.green),
                                            if (selected && !correct)
                                              const Icon(Icons.cancel, color: Colors.red),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _index > 0
                                    ? () => setState(() {
                                          _index--;
                                          _selectedOption = null;
                                        })
                                    : null,
                                child: const Text('Previous'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: _index < _cards.length - 1
                                    ? () => setState(() {
                                          _index++;
                                          _selectedOption = null;
                                        })
                                    : () => Navigator.pop(context),
                                child: Text(_index < _cards.length - 1 ? 'Next' : 'Finish'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
    );
  }
}

// -----------------------------------------------------------------------------
// FLASHCARD DIALOG FROM PDF
// -----------------------------------------------------------------------------
class _FlashcardDialogFromList extends StatefulWidget {
  final List<Flashcard> cards;
  final String title;
  const _FlashcardDialogFromList({
    required this.cards,
    required this.title,
  });

  @override
  State<_FlashcardDialogFromList> createState() => _FlashcardDialogFromListState();
}

class _FlashcardDialogFromListState extends State<_FlashcardDialogFromList> {
  int _index = 0;
  int? _selectedOption;

  void _selectOption(int index) {
    if (_selectedOption != null) return;
    setState(() => _selectedOption = index);
    final card = widget.cards[_index];
    final correct = index == card.correctIndex;
    // Use the app's simple toast rather than a snackbar.
    if (correct) {
      _showToast(success: true);
    } else {
      _showToast(success: false);
    }
  }

  void _showToast({required bool success}) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        left: 24,
        right: 24,
        bottom: 32,
        child: Material(
          color: Colors.transparent,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              decoration: BoxDecoration(
                color: success ? Colors.green.shade600 : Colors.red.shade600,
                borderRadius: BorderRadius.circular(28),
              ),
              child: Text(
                success ? 'Successful!' : 'Something went wrong!',
                style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 2), () {
      if (entry.mounted) entry.remove();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.cards.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Flashcards')),
        body: const Center(child: Text('No flashcards available.')),
      );
    }
    final card = widget.cards[_index];
    final hasOptions = card.options.length == 4;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Flashcards: ${widget.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
        ),
        backgroundColor: const Color(0xFF00C896),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              LinearProgressIndicator(
                value: (_index + 1) / widget.cards.length,
                minHeight: 7,
                borderRadius: BorderRadius.circular(8),
              ),
              const SizedBox(height: 18),
              Text(
                'Question ${_index + 1} of ${widget.cards.length}',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        elevation: 3,
                        child: Padding(
                          padding: const EdgeInsets.all(22),
                          child: _buildMathText(
                            card.question,
                            style: GoogleFonts.poppins(
                              fontSize: 21,
                              fontWeight: FontWeight.w600,
                            ),
                            align: TextAlign.center,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      if (hasOptions)
                        ...List.generate(4, (i) {
                          final selected = _selectedOption == i;
                          final correct = i == card.correctIndex;
                          Color? fill;
                          Color border = Theme.of(context).colorScheme.outline;
                          if (_selectedOption != null) {
                            if (correct) {
                              fill = Colors.green.shade100;
                              border = Colors.green;
                            } else if (selected) {
                              fill = Colors.red.shade100;
                              border = Colors.red;
                            }
                          }
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: InkWell(
                              onTap: () => _selectOption(i),
                              borderRadius: BorderRadius.circular(14),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: fill,
                                  border: Border.all(color: border, width: 2),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    CircleAvatar(
                                      radius: 15,
                                      child: Text(String.fromCharCode(65 + i)),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: _buildMathText(
                                        card.options[i],
                                        style: GoogleFonts.poppins(fontSize: 16),
                                      ),
                                    ),
                                    if (_selectedOption != null && correct)
                                      const Icon(Icons.check_circle, color: Colors.green),
                                    if (_selectedOption == i && !correct)
                                      const Icon(Icons.cancel, color: Colors.red),
                                  ],
                                ),
                              ),
                            ),
                          );
                        })
                      else
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'This flashcard was generated without four choices. Please regenerate it.',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.poppins(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _index > 0
                          ? () => setState(() {
                                _index--;
                                _selectedOption = null;
                              })
                          : null,
                      child: const Text('Previous'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _index < widget.cards.length - 1
                          ? () => setState(() {
                                _index++;
                                _selectedOption = null;
                              })
                          : () => Navigator.pop(context),
                      child: Text(_index < widget.cards.length - 1 ? 'Next' : 'Finish'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// GEMINI CHAT
// -----------------------------------------------------------------------------
// Full-screen AI tutor. Conversation is persisted for 24 hours.
// -----------------------------------------------------------------------------
class _GeminiChatSheet extends StatefulWidget {
  final GenerativeModel model;

  const _GeminiChatSheet({super.key, required this.model});

  @override
  State<_GeminiChatSheet> createState() => _GeminiChatSheetState();
}

class _GeminiChatSheetState extends State<_GeminiChatSheet> {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _chat = [];
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;

  static const String _chatStorageKey = 'exam_hook_ai_chat';
  static const String _chatTimeKey = 'exam_hook_ai_chat_time';
  static const Duration _chatLifetime = Duration(hours: 24);

  @override
  void initState() {
    super.initState();
    _loadChat();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _spaceCollapsedWords(String input) {
    var cleaned = input
        .replaceAll(RegExp(r'\*\*|\*|`|_'), '')
        .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
        .replaceAllMapped(RegExp(r'([A-Za-z])(\d)'), (m) => '${m[1]} ${m[2]}')
        .replaceAllMapped(RegExp(r'(\d)([A-Za-z])'), (m) => '${m[1]} ${m[2]}');

    const replacements = {
      'numberof': 'number of',
      'massof': 'mass of',
      'totalmass': 'total mass',
      'BindingEnergy': 'Binding Energy',
      'bindingenergy': 'binding energy',
      'speedoflight': 'speed of light',
      'massdefect': 'mass defect',
      'pernucleon': 'per nucleon',
      'gravitationalforce': 'gravitational force',
      'kineticenergy': 'kinetic energy',
      'potentialenergy': 'potential energy',
      'workdone': 'work done',
      'electriccurrent': 'electric current',
      'electricfield': 'electric field',
      'centripetalforce': 'centripetal force',
      'accelerationduetogravity': 'acceleration due to gravity',
    };

    replacements.forEach((from, to) {
      cleaned = cleaned.replaceAll(from, to);
    });

    return cleaned.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  }

  Future<void> _loadChat() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedTime = prefs.getInt(_chatTimeKey);
      final savedMessages = prefs.getStringList(_chatStorageKey);

      if (savedTime == null || savedMessages == null) return;

      final savedAt = DateTime.fromMillisecondsSinceEpoch(savedTime);
      if (DateTime.now().difference(savedAt) >= _chatLifetime) {
        await prefs.remove(_chatStorageKey);
        await prefs.remove(_chatTimeKey);
        return;
      }

      final restored = <Map<String, String>>[];
      for (final encoded in savedMessages) {
        try {
          final decoded = jsonDecode(encoded);
          if (decoded is Map) {
            final role = decoded['role']?.toString() ?? '';
            final text = decoded['text']?.toString() ?? '';
            if (role.isNotEmpty && text.isNotEmpty) {
              restored.add({'role': role, 'text': text});
            }
          }
        } catch (e) {
          debugPrint('Could not restore AI message: $e');
        }
      }

      if (!mounted) return;
      setState(() {
        _chat
          ..clear()
          ..addAll(restored);
      });
      _scrollToBottom();
    } catch (e) {
      debugPrint('AI chat load error: $e');
    }
  }

  Future<void> _saveChat() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = _chat.map((message) {
        return jsonEncode({
          'role': message['role'] ?? '',
          'text': message['text'] ?? '',
        });
      }).toList();

      await prefs.setStringList(_chatStorageKey, encoded);
      if (!prefs.containsKey(_chatTimeKey)) {
        await prefs.setInt(
          _chatTimeKey,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
    } catch (e) {
      debugPrint('AI chat save error: $e');
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _copyMessage(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      _showSimpleToast(context, success: true);
    } catch (e) {
      if (!mounted) return;
      _showSimpleToast(context, success: false);
    }
  }

  void _showMessageOptions(String text, bool isUser) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('Copy'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _copyMessage(text);
                },
              ),
              if (!isUser)
                ListTile(
                  leading: const Icon(Icons.reply_rounded),
                  title: const Text('Reply to this'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _controller.text = '@AI $text\n';
                    _controller.selection = TextSelection.fromPosition(
                      TextPosition(offset: _controller.text.length),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _clearChat() async {
    try {
      final shouldClear = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Clear AI Chat'),
            content: const Text('Are you sure you want to clear this chat?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Clear'),
              ),
            ],
          );
        },
      );

      if (shouldClear != true) return;

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_chatStorageKey);
      await prefs.remove(_chatTimeKey);

      if (!mounted) return;
      setState(() => _chat.clear());
      _showSimpleToast(context, success: true);
    } catch (e) {
      if (!mounted) return;
      _showSimpleToast(context, success: false);
    }
  }

  Future<void> _ask() async {
    final question = _controller.text.trim();
    if (question.isEmpty || _isLoading) return;

    setState(() {
      _chat.add({'role': 'user', 'text': question});
      _isLoading = true;
    });
    _controller.clear();
    await _saveChat();
    _scrollToBottom();

    try {
      final prompt = '''
You are ExamHook AI tutor for high school students in Zimbabwe.

Rules:
1. Do NOT use asterisks for bold or italic.
2. Use plain text with clear headings such as Definition:, Explanation:, Example:.
3. For formulas, write them in plain LaTeX without dollar signs.
4. Keep answers clear, well-spaced and easy to read.
5. Never join words together.
6. Use examples where useful.
7. Show calculation steps when solving mathematics or science questions.

Question:
$question
''';

      final response = await widget.model.generateContent([
        Content.text(prompt),
      ]);

      final answer = response.text?.trim();
      if (answer == null || answer.isEmpty) {
        throw Exception('Empty AI response');
      }

      if (!mounted) return;
      setState(() {
        _chat.add({
          'role': 'model',
          'text': _spaceCollapsedWords(answer),
        });
        _isLoading = false;
      });
      await _saveChat();
      _scrollToBottom();
      if (mounted) _showSimpleToast(context, success: true);
    } catch (e) {
      debugPrint('AI chat error: $e');
      if (!mounted) return;
      setState(() {
        _chat.add({
          'role': 'model',
          'text': 'Currently Chat with @SciWrapper at 0718502707',
        });
        _isLoading = false;
      });
      await _saveChat();
      _scrollToBottom();
      if (mounted) _showSimpleToast(context, success: false);
    }
  }

  Widget _messageBubble(Map<String, String> message, bool isDark) {
    final role = message['role'] ?? '';
    final text = message['text'] ?? '';
    final isUser = role == 'user';

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showMessageOptions(text, isUser),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.88,
          ),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          decoration: BoxDecoration(
            color: isUser
                ? const Color(0xFF00C896)
                : (isDark ? const Color(0xFF202020) : Colors.grey.shade100),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isUser ? 18 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 18),
            ),
          ),
          child: isUser
              ? SelectableText(
                  _spaceCollapsedWords(text),
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 15.5,
                    height: 1.6,
                    letterSpacing: 0.15,
                  ),
                )
              : _buildMathText(
                  _spaceCollapsedWords(text),
                  style: GoogleFonts.poppins(
                    color: isDark ? Colors.white : Colors.black87,
                    fontSize: 15.5,
                    height: 1.65,
                    letterSpacing: 0.15,
                  ),
                  align: TextAlign.left,
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.auto_awesome_rounded),
            const SizedBox(width: 8),
            Text(
              'ExamHook AI',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF00C896),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Clear chat',
            onPressed: _chat.isEmpty ? null : _clearChat,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _chat.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.auto_awesome_rounded,
                              size: 58,
                              color: Color(0xFF00C896),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Ask ExamHook AI',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.poppins(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Ask questions about your subjects, calculations, definitions and exam preparation.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.poppins(
                                fontSize: 14,
                                height: 1.5,
                                color: isDark ? Colors.white70 : Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
                      itemCount: _chat.length,
                      itemBuilder: (context, index) {
                        return _messageBubble(_chat[index], isDark);
                      },
                    ),
            ),
            if (_isLoading)
              const LinearProgressIndicator(minHeight: 2),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF151515) : Colors.white,
                boxShadow: [
                  BoxShadow(
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                    color: Colors.black.withOpacity(0.08),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Ask ExamHook AI...',
                        filled: true,
                        fillColor: isDark
                            ? const Color(0xFF242424)
                            : Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: const Color(0xFF00C896),
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: 'Send',
                      onPressed: _isLoading ? null : _ask,
                      color: Colors.white,
                      icon: const Icon(Icons.send_rounded),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
