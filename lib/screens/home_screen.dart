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
import 'package:flutter/services.dart'; // for Clipboard
import 'dart:typed_data';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'admin_dashboard.dart';
import 'pdf_viewer.dart';
import 'student_upload.dart';
// TODO: Move this to --dart-define for production

class Flashcard {
  final String question;
  final String answer;
  Flashcard({required this.question, required this.answer});
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
        widgets.add(SingleChildScrollView(scrollDirection: Axis.horizontal, child: Text(line, style: style, textAlign: align),),);
      }
    } else {
      widgets.add(SingleChildScrollView(scrollDirection: Axis.horizontal, child: Text(line, style: style, textAlign: align),),);
    }
    if (i < lines.length - 1) widgets.add(const SizedBox(height: 2));
  }
  return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: widgets,);
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

  late final GenerativeModel model; // <-- NOT nullable anymore

  @override
  void initState() {
    super.initState();
    
    // Crash here if key is missing so we know immediately
    if (widget.geminiApiKey.isEmpty) {
      throw Exception("GEMINI_API_KEY is missing. Build with --dart-define=GEMINI_API_KEY=your_key");
    }
    
    model = GenerativeModel( // <-- guaranteed to be init
      model: 'gemini-1.5-flash',
      apiKey: widget.geminiApiKey,
    );
    
    _loadPrefs();
  }
  
  @override
  void dispose() {
    _searchController.dispose();
    _requestController.dispose();
    super.dispose();
  }
  
  Future<void> _loadPrefs() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _themeMode = prefs.getString('theme_mode') ?? 'light';
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('My Uploads history cleared')),);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not clear upload history: $e'), backgroundColor: Colors.red),);
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Request sent to Admin!'),
                      backgroundColor: Colors.green,
                    ),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to send: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
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
    String title,
  ) async {
    await _saveRecent(docId);
    try {
      await _firestore
          .collection('resources')
          .doc(docId)
          .update({
        'downloads': FieldValue.increment(1),
      });
    } catch (e) {
      debugPrint('Download counter error: $e');
    }
    if (!mounted) return;
    try {
      final Uri uri = Uri.parse(url);
      if (kIsWeb) {
        if (await canLaunchUrl(uri)) {
          await launchUrl(
            uri,
            mode: LaunchMode.externalApplication,
          );
        }
        return;
      }
      if (url.toLowerCase().contains('.pdf')) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PdfViewerScreen(
              url: url,
              title: title,
            ),
          ),
        );
      } else {
        if (await canLaunchUrl(uri)) {
          await launchUrl(
            uri,
            mode: LaunchMode.externalApplication,
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open file: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
  // ---------------------------------------------------------------------------
  // AI FLASHCARDS FROM PDF
  // ---------------------------------------------------------------------------
  Future<void> _generateFlashcardsFromPdf(
    String pdfUrl,
    String title,
  ) async {
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
Generate 10 flashcards from this PDF for high school exam prep.
Rules:
1. Return ONLY a valid JSON array. No markdown, no asterisks, no explanation.
2. Format: [{"q": "question", "a": "answer"}]
3. For formulas write them in plain LaTeX without $ signs. Example: F = ma, E = mc^2, \frac{a}{b}, x^2
4. Keep answers short, max 15 words.
''',
      );
      final DataPart pdfData = DataPart(
        'application/pdf',
        pdfBytes,
      );
      final GenerateContentResponse result =
          await model.generateContent(
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
      showDialog(
        context: context,
        builder: (_) {
          return _FlashcardDialogFromList(
            cards: cards,
            title: title,
          );
        },
      );
    } catch (e) {
      if (mounted && !dialogClosed) {
        Navigator.pop(context);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to generate flashcards: $e',
            ),
            backgroundColor: Colors.red,
          ),
        );
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
    Share.share(
      'Check out "$title" on ExamHook\n$url',
    );
  }
  Future<void> _likeResource(String docId) async {
    if (likedDocs.contains(docId)) {
      return;
    }
    try {
      await _firestore
          .collection('resources')
          .doc(docId)
          .update({
        'likes': FieldValue.increment(1),
      });
      if (!mounted) return;
      setState(() {
        likedDocs.add(docId);
      });
    } catch (e) {
      debugPrint('Like error: $e');
    }
  }
  Future<void> _rateResource(
    String docId,
    double rating,
  ) async {
    if (ratedDocs.contains(docId)) {
      return;
    }
    try {
      final DocumentSnapshot doc =
          await _firestore
              .collection('resources')
              .doc(docId)
              .get();
      final dynamic rawRating =
          doc.data() is Map
              ? (doc.data() as Map)['rating']
              : null;
      final dynamic rawRatingCount =
          doc.data() is Map
              ? (doc.data() as Map)['ratingCount']
              : null;
      final double currentRating =
          rawRating is num
              ? rawRating.toDouble()
              : double.tryParse(
                    rawRating?.toString() ?? '',
                  ) ??
                  0.0;
      final int ratingCount =
          rawRatingCount is num
              ? rawRatingCount.toInt()
              : int.tryParse(
                    rawRatingCount?.toString() ?? '',
                  ) ??
                  0;
      final double newRating =
          ((currentRating * ratingCount) + rating) /
          (ratingCount + 1);
      await _firestore
          .collection('resources')
          .doc(docId)
          .update({
        'rating': newRating,
        'ratingCount': FieldValue.increment(1),
      });
      if (!mounted) return;
      setState(() {
        ratedDocs.add(docId);
      });
    } catch (e) {
      debugPrint('Rating error: $e');
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Admin Access Granted'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }
  // ---------------------------------------------------------------------------
  // GEMINI
  // ---------------------------------------------------------------------------
  void _showGeminiChat() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true, 
      builder: (_) => const _GeminiChatSheet(),
    );
  }
  void _showFlashcards(String subject) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return _FlashcardDialog(
          subject: subject,
        );
      },
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
                                              onPressed:
                                                  () =>
                                                      _likeResource(
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
  final GenerativeModel model,
  const _FlashcardDialog({
    required this.subject, required this.model, 
  });
  @override
  State<_FlashcardDialog> createState() =>
      _FlashcardDialogState();
}
class _FlashcardDialogState
    extends State<_FlashcardDialog> {
  List<Flashcard> _cards = [];
  bool _isLoading = true;
  int _index = 0;
  bool _showAnswer = false;
  @override
  void initState() {
    super.initState();
    _generate();
  }
  Future<void> _generate() async {
    try {
      final String prompt =
          '''
Generate 10 flashcards for ${widget.subject} for high school exams.
Rules:
1. Return ONLY a valid JSON array. No markdown, no asterisks, no explanation.
2. Format: [{"q": "question", "a": "answer"}]
3. For formulas write them in plain LaTeX without \$ signs. Example: F = ma, E = mc^2, \\frac{a}{b}, x^2
4. Keep answers short, max 15 words.
''';
      final GenerateContentResponse response =
          await model.generateContent([
        Content.text(prompt),
      ]);
      String text = response.text ?? '';
      text = text
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();
      final dynamic decoded = jsonDecode(text);
      if (decoded is! List) {
        throw Exception(
          'Invalid AI response',
        );
      }
      final List<Flashcard> cards = decoded
          .whereType<Map>()
          .map(
            (e) => Flashcard(
              question:
                  e['q']?.toString() ?? '',
              answer:
                  e['a']?.toString() ?? '',
            ),
          )
          .where(
            (card) =>
                card.question.isNotEmpty &&
                card.answer.isNotEmpty,
          )
          .toList();
      if (!mounted) return;
      setState(() {
        _cards = cards;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }
  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        height: 400,
        padding: const EdgeInsets.all(16),
        child: _isLoading
            ? const Center(
                child:
                    CircularProgressIndicator(),
              )
            : _cards.isEmpty
                ? Center(
                    child: Text(
                      'Could not generate flashcards.',
                      style:
                          GoogleFonts.poppins(),
                    ),
                  )
                : Column(
                    children: [
                      Text(
                        '${widget.subject} Flashcards',
                        style:
                            GoogleFonts.poppins(
                          fontSize: 20,
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                      const SizedBox(
                        height: 20,
                      ),
                      Expanded(
                        child:
                            GestureDetector(
                          onTap: () {
                            setState(() {
                              _showAnswer =
                                  !_showAnswer;
                            });
                          },
                          child: Card(
                            color:
                                const Color(
                              0xFF00C896,
                            ),
                            child: Center(
                              child: Padding(
                                padding:
                                    const EdgeInsets
                                        .all(
                                  20,
                                ),
                                child:
                                    _buildMathText(
                                  _showAnswer
                                      ? _cards[
                                          _index]
                                          .answer
                                      : _cards[
                                          _index]
                                          .question,
                                  style:
                                      GoogleFonts
                                          .poppins(
                                    fontSize:
                                        22,
                                    color:
                                        Colors
                                            .white,
                                  ),
                                  align:
                                      TextAlign
                                          .center,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        mainAxisAlignment:
                            MainAxisAlignment
                                .spaceBetween,
                        children: [
                          TextButton(
                            onPressed:
                                _index > 0
                                    ? () {
                                        setState(
                                          () {
                                            _index--;
                                            _showAnswer =
                                                false;
                                          },
                                        );
                                      }
                                    : null,
                            child:
                                const Text(
                              'Prev',
                            ),
                          ),
                          Text(
                            '${_index + 1}/${_cards.length}',
                          ),
                          TextButton(
                            onPressed:
                                _index <
                                        _cards.length -
                                            1
                                    ? () {
                                        setState(
                                          () {
                                            _index++;
                                            _showAnswer =
                                                false;
                                          },
                                        );
                                      }
                                    : null,
                            child:
                                const Text(
                              'Next',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
      ),
    );
  }
}
// -----------------------------------------------------------------------------
// FLASHCARD DIALOG FROM PDF
// -----------------------------------------------------------------------------
class _FlashcardDialogFromList
    extends StatefulWidget {
  final List<Flashcard> cards;
  final String title;
  const _FlashcardDialogFromList({
    required this.cards,
    required this.title,
  });
  @override
  State<_FlashcardDialogFromList> createState() =>
      _FlashcardDialogFromListState();
}
class _FlashcardDialogFromListState
    extends State<_FlashcardDialogFromList> {
  int _index = 0;
  bool _showAnswer = false;
  @override
  Widget build(BuildContext context) {
    if (widget.cards.isEmpty) {
      return const Dialog(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No flashcards available.',
          ),
        ),
      );
    }
    return Dialog(
      child: Container(
        height: 400,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              'Flashcards from: ${widget.title}',
              maxLines: 2,
              overflow:
                  TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                fontSize: 18,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
            const SizedBox(
              height: 20,
            ),
            Expanded(
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _showAnswer =
                        !_showAnswer;
                  });
                },
                child: Card(
                  color:
                      const Color(0xFF00C896),
                  child: Center(
                    child: Padding(
                      padding:
                          const EdgeInsets
                              .all(
                        20,
                      ),
                      child: _buildMathText(
                        _showAnswer
                            ? widget
                                .cards[
                                    _index]
                                .answer
                            : widget
                                .cards[
                                    _index]
                                .question,
                        style:
                            GoogleFonts.poppins(
                          fontSize: 22,
                          color:
                              Colors.white,
                        ),
                        align:
                            TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Row(
              mainAxisAlignment:
                  MainAxisAlignment
                      .spaceBetween,
              children: [
                TextButton(
                  onPressed:
                      _index > 0
                          ? () {
                              setState(
                                () {
                                  _index--;
                                  _showAnswer =
                                      false;
                                },
                              );
                            }
                          : null,
                  child:
                      const Text('Prev'),
                ),
                Text(
                  '${_index + 1}/${widget.cards.length}',
                ),
                TextButton(
                  onPressed:
                      _index <
                              widget.cards.length -
                                  1
                          ? () {
                              setState(
                                () {
                                  _index++;
                                  _showAnswer =
                                      false;
                                },
                              );
                            }
                          : null,
                  child:
                      const Text('Next'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// GEMINI CHAT
// -----------------------------------------------------------------------------
// Conversation is persisted for 24 hours using SharedPreferences.
// After 24 hours the stored conversation is automatically removed.
// -----------------------------------------------------------------------------
class _GeminiChatSheet
    extends StatefulWidget {
  const _GeminiChatSheet();
  @override
  State<_GeminiChatSheet> createState() =>
      _GeminiChatSheetState();
}
class _GeminiChatSheetState
    extends State<_GeminiChatSheet> {
  final TextEditingController _controller =
      TextEditingController();
      
  final List<Map<String, String>> _chat =
      [];
  bool _isLoading = false;
  final ScrollController _scrollController =
      ScrollController();
  // Keys used to save the AI conversation.
  static const String _chatStorageKey =
      'exam_hook_ai_chat';
  static const String _chatTimeKey =
      'exam_hook_ai_chat_time';
  // Conversation lifetime.
  static const Duration _chatLifetime =
      Duration(hours: 24);
     
     Widget _renderGeminiText(String text, BuildContext context, String originalText) {
  // 1. Strip markdown that causes sticking
  String cleaned = text
      .replaceAll('*', '')
      .replaceAll('_', '')
      .replaceAll('`', '')
      .trim();

  // 2. Fix common collapsed words from Gemini
  cleaned = cleaned
      .replaceAll('numberof', 'number of')
      .replaceAll('massof', 'mass of')
      .replaceAll('totalmass', 'total mass')
      .replaceAll('BindingEnergy', 'Binding Energy')
      .replaceAll('speedoflight', 'speed of light')
      .replaceAll('massdefect', 'mass defect')
      .replaceAll('pernucleon', 'per nucleon');

  return GestureDetector(
    onLongPress: () {
      _showMessageOptions(context, originalText, false); // false = AI message
    },
    child: SingleChildScrollView( // <-- HORIZONTAL SCROLL
      scrollDirection: Axis.horizontal,
      child: SelectableText( // <-- COPYABLE
        cleaned,
        style: GoogleFonts.poppins(
          color: Colors.black,
          fontSize: 15,
          height: 1.6,
        ),
        textAlign: TextAlign.left,
      ),
    ),
  );
}
    

void _showMessageOptions(BuildContext context, String message, bool isUser) {
  showModalBottomSheet(
    context: context,
    builder: (_) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: message));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard')),
                );
              },
            ),
            if (!isUser) // Only allow reply to AI
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply to this'),
                onTap: () {
                  Navigator.pop(context);
                  _controller.text = "@AI $message\n"; // prefill with quote
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
  // ---------------------------------------------------------------------------
  // LOAD AI CHAT
  // ---------------------------------------------------------------------------
  Future<void> _loadChat() async {
    try {
      final SharedPreferences prefs =
          await SharedPreferences.getInstance();
      final int? savedTime =
          prefs.getInt(_chatTimeKey);
      final List<String>? savedMessages =
          prefs.getStringList(
        _chatStorageKey,
      );
      if (savedTime == null ||
          savedMessages == null ||
          savedMessages.isEmpty) {
        return;
      }
      final DateTime savedAt =
          DateTime.fromMillisecondsSinceEpoch(
        savedTime,
      );
      final Duration age =
          DateTime.now().difference(savedAt);
      // Automatically remove conversation after 24 hours.
      if (age >= _chatLifetime) {
        await prefs.remove(_chatStorageKey);
        await prefs.remove(_chatTimeKey);
        return;
      }
      final List<Map<String, String>>
          restoredChat = [];
      for (final String encoded
          in savedMessages) {
        try {
          final dynamic decoded =
              jsonDecode(encoded);
          if (decoded is Map) {
            final String role =
                decoded['role']?.toString() ?? '';
            final String text =
                decoded['text']?.toString() ?? '';
            if (role.isNotEmpty &&
                text.isNotEmpty) {
              restoredChat.add({
                'role': role,
                'text': text,
              });
            }
          }
        } catch (e) {
          debugPrint(
            'Could not restore AI message: $e',
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _chat.clear();
        _chat.addAll(restoredChat);
      });
      _scrollToBottom();
    } catch (e) {
      debugPrint(
        'AI chat load error: $e',
      );
    }
  }
  // ---------------------------------------------------------------------------
  // SAVE AI CHAT
  // ---------------------------------------------------------------------------
  Future<void> _saveChat() async {
    try {
      final SharedPreferences prefs =
          await SharedPreferences.getInstance();
      final List<String> encodedMessages =
          _chat.map((message) {
        return jsonEncode({
          'role': message['role'] ?? '',
          'text': message['text'] ?? '',
        });
      }).toList();
      await prefs.setStringList(
        _chatStorageKey,
        encodedMessages,
      );
      // Only set the timestamp if this conversation
      // does not already have one.
      if (!prefs.containsKey(_chatTimeKey)) {
        await prefs.setInt(
          _chatTimeKey,
          DateTime.now()
              .millisecondsSinceEpoch,
        );
      }
    } catch (e) {
      debugPrint(
        'AI chat save error: $e',
      );
    }
  }
  // ---------------------------------------------------------------------------
  // CLEAR EXPIRED CHAT
  // ---------------------------------------------------------------------------
  Future<void> _clearExpiredChatIfNeeded() async {
    try {
      final SharedPreferences prefs =
          await SharedPreferences.getInstance();
      final int? savedTime =
          prefs.getInt(_chatTimeKey);
      if (savedTime == null) {
        return;
      }
      final DateTime savedAt =
          DateTime.fromMillisecondsSinceEpoch(
        savedTime,
      );
      if (DateTime.now().difference(savedAt) >=
          _chatLifetime) {
        await prefs.remove(_chatStorageKey);
        await prefs.remove(_chatTimeKey);
        if (!mounted) return;
        setState(() {
          _chat.clear();
        });
      }
    } catch (e) {
      debugPrint(
        'AI chat expiry error: $e',
      );
    }
  }
  // ---------------------------------------------------------------------------
  // SCROLL
  // ---------------------------------------------------------------------------
  void _scrollToBottom() {
    Future.delayed(
      const Duration(milliseconds: 150),
      () {
        if (!_scrollController.hasClients) {
          return;
        }
        _scrollController.animateTo(
          0,
          duration:
              const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      },
    );
  }
  // ---------------------------------------------------------------------------
  // ASK AI
  // ---------------------------------------------------------------------------
  Future<void> _ask() async {
    await _clearExpiredChatIfNeeded();
    final String question =
        _controller.text.trim();
    if (question.isEmpty ||
        _isLoading) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _chat.add({
        'role': 'user',
        'text': question,
      });
      _isLoading = true;
    });
    _controller.clear();
    // Save immediately so the user message survives
    // closing/reopening the AI sheet.
    await _saveChat();
    try {
      final String prompt =
          '''
You are ExamHook AI tutor for high school students in Zimbabwe.
Rules:
1. Do NOT use asterisks for bold or italic.
2. Use plain text with headings like "Definition:"
3. For formulas write them in plain LaTeX without \$ signs. Example: F = ma, E = mc^2, \\\\frac{a}{b}, x^2, \\\\sqrt{b^2 - 4ac}
4. Keep answers clear, short, with examples.
Question: $question
''';
      final GenerateContentResponse response =
          await model.generateContent([
        Content.text(prompt),
      ]);
      if (!mounted) return;
      setState(() {
        final String aiResponse = response.text?.trim() ?? '';
        _chat.add({
          'role': 'ai',
          'text': aiResponse.isNotEmpty
              ? aiResponse
              : 'Currently Chat with @SciWrapper at 0718502707',
        });
        _isLoading = false;
      });
      await _saveChat();
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _chat.add({
          'role': 'ai',
          'text': 'Currently Chat with @SciWrapper at 0718502707',
        });
        _isLoading = false;
      });
      await _saveChat();
      _scrollToBottom();
    }
  }
  // ---------------------------------------------------------------------------
  // BUILD AI CHAT
  // ---------------------------------------------------------------------------
@override
Widget build(BuildContext context) {
  return SafeArea(
    bottom: false, // let us handle bottom padding manually
    child: Container(
      height: MediaQuery.of(context).size.height * 0.85,
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom, // pushes up with keyboard
      ),
      child: Column(
        children: [
          AppBar(
            title: Text(
              'Ask ExamHook AI',
              style: GoogleFonts.poppins(),
            ),
            automaticallyImplyLeading: false,
            backgroundColor: const Color(0xFF00C896),
            actions: [
              IconButton(
                tooltip: 'Clear AI conversation',
                icon: const Icon(Icons.delete_outline),
                onPressed: _chat.isEmpty
                    ? null
                    : () async {
                        final bool? confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) {
                            return AlertDialog(
                              title: const Text('Clear conversation?'),
                              content: const Text(
                                'This will remove the saved AI conversation.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(dialogContext, false),
                                  child: const Text('Cancel'),
                                ),
                                ElevatedButton(
                                  onPressed: () =>
                                      Navigator.pop(dialogContext, true),
                                  child: const Text('Clear'),
                                ),
                              ],
                            );
                          },
                        );
                        if (confirmed != true) return;
                        try {
                          final SharedPreferences prefs =
                              await SharedPreferences.getInstance();
                          await prefs.remove(_chatStorageKey);
                          await prefs.remove(_chatTimeKey);
                          if (!mounted) return;
                          setState(() {
                            _chat.clear();
                          });
                        } catch (e) {
                          debugPrint('Clear AI chat error: $e');
                        }
                      },
              ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              reverse: true,
              // FIX 1: HUGE bottom padding. Accounts for input row + keyboard
              padding: EdgeInsets.only(
                top: 12,
                left: 12,
                right: 12,
                bottom: 160 + MediaQuery.of(context).viewInsets.bottom,
              ),
              physics: const AlwaysScrollableScrollPhysics(),
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              itemCount: _chat.length,
              itemBuilder: (context, i) {
                final Map<String, String> msg = _chat[_chat.length - 1 - i];
                final bool isUser = msg['role'] == 'user';
                return Align(
                  alignment:
                      isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: GestureDetector( // Wrap container for long press on both
                    onLongPress: () {
                      _showMessageOptions(context, msg['text'] ?? '', isUser);
                    },
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.all(12),
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.8,
                      ),
                      decoration: BoxDecoration(
                        color: isUser
                            ? const Color(0xFF00C896)
                            : Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: SingleChildScrollView( // <-- FIX: horizontal scroll
                        scrollDirection: Axis.horizontal,
                        child: isUser
                            ? SelectableText( // COPYABLE user text
                                msg['text'] ?? '',
                                style: GoogleFonts.poppins(
                                  color: Colors.white,
                                  fontSize: 15,
                                  height: 1.5,
                                ),
                              )
                            : _buildMathText( // AI: render LaTeX + horizontal scroll
                                msg['text'] ?? '',
                                style: GoogleFonts.poppins(
                                  color: Colors.black,
                                  fontSize: 15,
                                  height: 1.6,
                                ),
                                align: TextAlign.left,
                              ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_isLoading) const LinearProgressIndicator(minHeight: 2),
          // FIX 2: Wrap input in Padding so it sits above keyboard
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    onSubmitted: (_) => _ask(),
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Ask about Maths, Physics...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: const Color(0xFF00C896),
                  child: IconButton(
                    icon: const Icon(
                      Icons.send,
                      color: Colors.white,
                      size: 20,
                    ),
                    onPressed: _ask,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom), // for iPhone home bar
        ],
      ),
    ),
  );
}
} 