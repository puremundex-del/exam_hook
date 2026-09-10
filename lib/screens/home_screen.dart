Import ‘package:flutter/material.dart’;
Import ‘package:cloud_firestore/cloud_firestore.dart’;
Import ‘package:google_fonts/google_fonts.dart’;
Import ‘package:url_launcher/url_launcher.dart’;
Import ‘package:intl/intl.dart’;
Import ‘package:shared_preferences/shared_preferences.dart’;
Import ‘package:share_plus/share_plus.dart’;
Import ‘package:flutter/foundation.dart’ show kIsWeb;
Import ‘package:google_generative_ai/google_generative_ai.dart’;
Import ‘package:http/http.dart’ as http;
Import ‘package:flutter_math_fork/flutter_math.dart’;
Import ‘dart:convert’;
Import ‘dart:typed_data’;

Import ‘admin_dashboard.dart’;
Import ‘pdf_viewer.dart’;
Import ‘student_upload.dart’;

// TODO: Move this to –dart-define for production
const String _geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

Final model = GenerativeModel(
  Model: ‘gemini-3.5-flash-lite’,
  apiKey: _geminiApiKey,
);

Class Flashcard {
  Final String question;
  Final String answer;

  Flashcard({
Required this.question,
Required this.answer,
  });
}

// -----------------------------------------------------------------------------
// HELPER: Auto-detect and render LaTeX without $ signs
// -----------------------------------------------------------------------------

Widget _buildMathText(
  String text, {
  TextStyle? Style,
  TextAlign align = TextAlign.left,
}) {
  Final List<Widget> widgets = [];
  Final List<String> lines = text.split(‘\n’);

  For (int I = 0; I < lines.length; i++) {
Final String line = lines[i].trim();

If (line.isEmpty) {
      Continue;
}

Final bool looksLikeMath =
        RegExp(
          R’[=^_]|\\frac|\\sqrt|\\alpha|\\beta|\\gamma|\\pi|\\theta|\\pm’,
        ).hasMatch(line) &&
        Line.length < 150;

If (looksLikeMath) {
      Try {
        Widgets.add(
          Center(
            Child: Padding(
              Padding: const EdgeInsets.symmetric(vertical: 4),
              Child: Math.tex(
                Line,
                mathStyle: MathStyle.display,
                textStyle: style?.copyWith(
                  fontSize: (style.fontSize ?? 16) + 2,
                ),
              ),
            ),
          ),
        );
      } catch € {
        Widgets.add(
          Text(
            Line,
            Style: style,
            textAlign: align,
          ),
        );
      }
} else {
      Widgets.add(
        Text(
          Line,
          Style: style,
          textAlign: align,
        ),
      );
}

If (I < lines.length – 1) {
      Widgets.add(const SizedBox(height: 2));
}
  }

  Return Column(
mainAxisSize: MainAxisSize.min,
crossAxisAlignment: CrossAxisAlignment.start,
children: widgets,
  );
}

Class HomeScreen extends StatefulWidget {
  Const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

Class _HomeScreenState extends State<HomeScreen> {
  Final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Final TextEditingController _searchController = TextEditingController();
  Final TextEditingController _requestController = TextEditingController();

  String selectedCourse = ‘All’;
  String searchQuery = ‘’;

  Final Set<String> likedDocs = {};
  Final Set<String> ratedDocs = {};
  Set<String> favoriteDocs = {};
  Set<String> recentlyViewed = {};

  // Values saved by StudentUploadScreen.
  // They can be fileName, fileUrl, document ID, title, etc.
  List<String> myUploads = [];

  String _themeMode = ‘light’;

  Int _tapCount = 0;
  DateTime? _lastTapTime;

  Final List<Color> _cardColors = [
Const Color(0xFF00C896),
Const Color(0xFF3B82F6),
Const Color(0xFFF59E0B),
Const Color(0xFFEC4899),
Const Color(0xFF8B5CF6),
  ];

  @override
  Void initState() {
Super.initState();
_loadPrefs();
  }

  @override
  Void dispose() {
    _searchController.dispose();
    _requestController.dispose();
Super.dispose();
  }

  // ---------------------------------------------------------------------------
  // PREFERENCES
  // ---------------------------------------------------------------------------

  Future<void> _loadPrefs() async {
Try {
      Final SharedPreferences prefs =
          Await SharedPreferences.getInstance();

      If (!mounted) return;

      setState(() {
        _themeMode = prefs.getString(‘theme_mode’) ?? ‘light’;

        favoriteDocs = Set<String>.from(
          prefs.getStringList(‘favorites’) ?? [],
        );

        recentlyViewed = Set<String>.from(
          prefs.getStringList(‘recent’) ?? [],
        );

        myUploads = prefs.getStringList(‘my_uploads’) ?? [];
      });

      Await _checkTerms();
} catch € {
      debugPrint(‘Prefs error: $e’);
}
  }

  // ---------------------------------------------------------------------------
  // MY UPLOADS
  // ---------------------------------------------------------------------------

  Future<void> _clearUploadHistory() async {
Try {
      Final SharedPreferences prefs =
          Await SharedPreferences.getInstance();

      Await prefs.remove(‘my_uploads’);

      If (!mounted) return;

      setState(() {
        myUploads.clear();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        Const SnackBar(
          Content: Text(‘My Uploads history cleared’),
        ),
      );
} catch € {
      If (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          Content: Text(‘Could not clear upload history: $e’),
          backgroundColor: Colors.red,
        ),
      );
}
  }

  String _normalizeUploadValue(dynamic value) {
Return value?.toString().trim().toLowerCase() ?? ‘’;
  }

  // Checks multiple identifiers so uploads remain visible
  // whether pending, approved or rejected.
  Bool _isMyUpload(QueryDocumentSnapshot doc) {
Final dynamic rawData = doc.data();

If (rawData is! Map) {
      Return false;
}

Final Map<String, dynamic> data =
        Map<String, dynamic>.from(rawData);

Final Set<String> documentIdentifiers = {
      _normalizeUploadValue(doc.id),
      _normalizeUploadValue(data[‘id’]),
      _normalizeUploadValue(data[‘fileName’]),
      _normalizeUploadValue(data[‘fileUrl’]),
      _normalizeUploadValue(data[‘url’]),
      _normalizeUploadValue(data[‘title’]),
      _normalizeUploadValue(data[‘uploadId’]),
      _normalizeUploadValue(data[‘resourceId’]),
};

    documentIdentifiers.removeWhere(
      (value) => value.isEmpty,
);

For (final String savedUpload in myUploads) {
      Final String normalizedSaved =
          _normalizeUploadValue(savedUpload);

      If (normalizedSaved.isEmpty) {
        Continue;
      }

      If (documentIdentifiers.contains(normalizedSaved)) {
        Return true;
      }

      For (final String identifier in documentIdentifiers) {
        If (identifier == normalizedSaved) {
          Return true;
        }

        If (identifier.endsWith(normalizedSaved) ||
            normalizedSaved.endsWith(identifier)) {
          return true;
        }
      }
}

Return false;
  }

  String _getUploadStatus(
    QueryDocumentSnapshot doc, {
Required bool isPendingCollection,
  }) {
Final dynamic rawData = doc.data();

If (rawData is! Map) {
      Return isPendingCollection ? ‘Pending’ : ‘Approved’;
}

Final Map<String, dynamic> data =
        Map<String, dynamic>.from(rawData);

Final dynamic rawStatus =
        Data[‘status’] ??
        Data[‘uploadStatus’] ??
        Data[‘reviewStatus’];

Final String status =
        rawStatus?.toString().trim().toLowerCase() ?? ‘’;

if (status.contains(‘reject’)) {
      return ‘Rejected’;
}

If (status.contains(‘pending’) ||
        Status.contains(‘review’) ||
        Status.contains(‘waiting’)) {
      Return ‘Pending’;
}

If (status.contains(‘approv’)) {
      Return ‘Approved’;
}

If (isPendingCollection) {
      Return ‘Pending’;
}

Return ‘Approved’;
  }

  Color _getStatusColor(String status) {
Switch (status.toLowerCase()) {
      Case ‘approved’:
        Return Colors.green;
      Case ‘rejected’:
        Return Colors.red;
      Case ‘pending’:
      Default:
        Return Colors.orange;
}
  }

  IconData _getStatusIcon(String status) {
Switch (status.toLowerCase()) {
      Case ‘approved’:
        Return Icons.check_circle;
      Case ‘rejected’:
        Return Icons.cancel;
      Case ‘pending’:
      Default:
        Return Icons.pending;
}
  }

  // ---------------------------------------------------------------------------
  // RECENT / FAVORITES / THEME
  // ---------------------------------------------------------------------------

  Future<void> _saveRecent(String docId) async {
Try {
      Final SharedPreferences prefs =
          Await SharedPreferences.getInstance();

      If (!mounted) return;

      setState(() {
        recentlyViewed.remove(docId);
        recentlyViewed.add(docId);

        if (recentlyViewed.length > 10) {
          recentlyViewed.remove(recentlyViewed.first);
        }
      });

      Await prefs.setStringList(
        ‘recent’,
        recentlyViewed.toList(),
      );
} catch € {
      debugPrint(‘Recent error: $e’);
}
  }

  Future<void> _toggleFavorite(String docId) async {
Try {
      Final SharedPreferences prefs =
          Await SharedPreferences.getInstance();

      If (!mounted) return;

      setState(() {
        if (favoriteDocs.contains(docId)) {
          favoriteDocs.remove(docId);
        } else {
          favoriteDocs.add(docId);
        }
      });

      Await prefs.setStringList(
        ‘favorites’,
        favoriteDocs.toList(),
      );
} catch € {
      debugPrint(‘Favorite error: $e’);
}
  }

  Future<void> _saveTheme(String theme) async {
Final SharedPreferences prefs =
        Await SharedPreferences.getInstance();

Await prefs.setString(‘theme_mode’, theme);

If (!mounted) return;

setState(() {
      _themeMode = theme;
});
  }

  // ---------------------------------------------------------------------------
  // TERMS
  // ---------------------------------------------------------------------------

  Future<void> _checkTerms() async {
Final SharedPreferences prefs =
        Await SharedPreferences.getInstance();

Final bool accepted =
        Prefs.getBool(‘terms_accepted’) ?? false;

If (!accepted && mounted) {
      _showTermsDialog();
}
  }

  Void _showTermsDialog() {
showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            ‘Terms & Conditions’,
            Style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold,
            ),
          ),
          Content: SingleChildScrollView(
            Child: Text(
              ‘By using ExamHook you agree to:\n\n’
              ‘1. Resources are for educational purposes only.\n’
              ‘2. Do not redistribute files without permission.\n’
              ‘3. Admin reserves the right to remove content.\n’
              ‘4. We collect anonymous usage stats to improve the app.’,
              Style: GoogleFonts.poppins(
                fontSize: 14,
              ),
            ),
          ),
          Actions: [
            TextButton(
              onPressed: () async {
                final SharedPreferences prefs =
                    await SharedPreferences.getInstance();

                await prefs.setBool(
                  ‘terms_accepted’,
                  True,
                );

                If (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
              },
              Child: const Text(
                ‘Accept’,
                Style: TextStyle(
                  Color: Color(0xFF00C896),
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

  Void _showRequestDialog() {
    _requestController.clear();

showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            ‘Request Notes’,
            Style: GoogleFonts.poppins(
              fontWeight: FontWeight.bold,
            ),
          ),
          Content: TextField(
            Controller: _requestController,
            Decoration: const InputDecoration(
              labelText: ‘What subject/topic do you need?’,
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
          ),
          Actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
              },
              Child: const Text(‘Cancel’),
            ),
            ElevatedButton(
              onPressed: () async {
                final String request =
                    _requestController.text.trim();

                If (request.isEmpty) {
                  Return;
                }

                Try {
                  Await _firestore.collection(‘requests’).add({
                    ‘subject’: request,
                    ‘message’: ‘User requested: $request’,
                    ‘timestamp’: FieldValue.serverTimestamp(),
                    ‘status’: ‘pending’,
                  });

                  If (dialogContext.mounted) {
                    Navigator.pop(dialogContext);
                  }

                  If (!mounted) return;

                  ScaffoldMessenger.of(context).showSnackBar(
                    Const SnackBar(
                      Content: Text(‘Request sent to Admin!’),
                      backgroundColor: Colors.green,
                    ),
                  );
                } catch € {
                  If (!mounted) return;

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      Content: Text(‘Failed to send: $e’),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              Style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00C896),
              ),
              Child: const Text(‘Send Request’),
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
Await _saveRecent(docId);

Try {
      Await _firestore
          .collection(‘resources’)
          .doc(docId)
          .update({
        ‘downloads’: FieldValue.increment(1),
      });
} catch € {
      debugPrint(‘Download counter error: $e’);
}

If (!mounted) return;

Try {
      Final Uri uri = Uri.parse(url);

      If (kIsWeb) {
        If (await canLaunchUrl(uri)) {
          Await launchUrl(
            Uri,
            Mode: LaunchMode.externalApplication,
          );
        }
        Return;
      }

      If (url.toLowerCase().contains(‘.pdf’)) {
        Await Navigator.push(
          Context,
          MaterialPageRoute(
            Builder: (_) => PdfViewerScreen(
              url: url,
              title: title,
            ),
          ),
        );
      } else {
        If (await canLaunchUrl(uri)) {
          Await launchUrl(
            Uri,
            Mode: LaunchMode.externalApplication,
          );
        }
      }
} catch € {
      If (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          Content: Text(‘Could not open file: $e’),
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

Bool dialogClosed = false;

Try {
      Final http.Response response =
          Await http.get(Uri.parse(pdfUrl));

      If (response.statusCode < 200 ||
          Response.statusCode >= 300) {
        Throw Exception(
          ‘Could not download PDF (${response.statusCode})’,
        );
      }

      Final Uint8List pdfBytes = response.bodyBytes;

      Final TextPart prompt = TextPart(
        R’’’
Generate 10 flashcards from this PDF for high school exam prep.

Rules:
1. Return ONLY a valid JSON array. No markdown, no asterisks, no explanation.
2. Format: [{“q”: “question”, “a”: “answer”}]
3. For formulas write them in plain LaTeX without $ signs. Example: F = ma, E = mc^2, \frac{a}{b}, x^2
4. Keep answers short, max 15 words.
‘’’,
      );

      Final DataPart pdfData = DataPart(
        ‘application/pdf’,
        pdfBytes,
      );

      Final GenerateContentResponse result =
          Await model.generateContent(
        [
          Content.multi([
            Prompt,
            pdfData,
          ]),
        ],
      );

      If (mounted) {
        Navigator.pop(context);
        dialogClosed = true;
      }

      String text = result.text ?? ‘’;

      Text = text
          .replaceAll(‘```json’, ‘’)
          .replaceAll(‘```’, ‘’)
          .trim();

      Final dynamic decoded = jsonDecode(text);

      If (decoded is! List) {
        Throw Exception(
          ‘AI returned invalid flashcard data’,
        );
      }

      Final List<Flashcard> cards = decoded
          .whereType<Map>()
          .map(
            € => Flashcard(
              Question: e[‘q’]?.toString() ?? ‘’,
              Answer: e[‘a’]?.toString() ?? ‘’,
            ),
          )
          .where(
            (card) =>
                Card.question.isNotEmpty &&
                Card.answer.isNotEmpty,
          )
          .toList();

      If (cards.isEmpty) {
        Throw Exception(‘No flashcards were generated’);
      }

      If (!mounted) return;

      showDialog(
        context: context,
        builder: (_) {
          return _FlashcardDialogFromList(
            cards: cards,
            title: title,
          );
        },
      );
} catch € {
      If (mounted && !dialogClosed) {
        Navigator.pop(context);
      }

      If (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            Content: Text(
              ‘Failed to generate flashcards: $e’,
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

  Void _shareResource(
String title,
String url,
  ) {
Share.share(
      ‘Check out “$title” on ExamHook\n$url’,
);
  }

  Future<void> _likeResource(String docId) async {
If (likedDocs.contains(docId)) {
      Return;
}

Try {
      Await _firestore
          .collection(‘resources’)
          .doc(docId)
          .update({
        ‘likes’: FieldValue.increment(1),
      });

      If (!mounted) return;

      setState(() {
        likedDocs.add(docId);
      });
} catch € {
      debugPrint(‘Like error: $e’);
}
  }

  Future<void> _rateResource(
String docId,
Double rating,
  ) async {
If (ratedDocs.contains(docId)) {
      Return;
}

Try {
      Final DocumentSnapshot doc =
          Await _firestore
              .collection(‘resources’)
              .doc(docId)
              .get();

      Final dynamic rawRating =
          Doc.data() is Map
              ? (doc.data() as Map)[‘rating’]
              : null;

      Final dynamic rawRatingCount =
          Doc.data() is Map
              ? (doc.data() as Map)[‘ratingCount’]
              : null;

      Final double currentRating =
          rawRating is num
              ? rawRating.toDouble()
              : double.tryParse(
                    rawRating?.toString() ?? ‘’,
                  ) ??
                  0.0;

      Final int ratingCount =
          rawRatingCount is num
              ? rawRatingCount.toInt()
              : int.tryParse(
                    rawRatingCount?.toString() ?? ‘’,
                  ) ??
                  0;

      Final double newRating =
          ((currentRating * ratingCount) + rating) /
          (ratingCount + 1);

      Await _firestore
          .collection(‘resources’)
          .doc(docId)
          .update({
        ‘rating’: newRating,
        ‘ratingCount’: FieldValue.increment(1),
      });

      If (!mounted) return;

      setState(() {
        ratedDocs.add(docId);
      });
} catch € {
      debugPrint(‘Rating error: $e’);
}
  }

  // ---------------------------------------------------------------------------
  // ADMIN ACCESS
  // ---------------------------------------------------------------------------

  Void _handleHeaderTap() {
Final DateTime now = DateTime.now();

If (_lastTapTime == null ||
        Now.difference(_lastTapTime!) >
            Const Duration(seconds: 2)) {
      _tapCount = 1;
} else {
      _tapCount++;
}

_lastTapTime = now;

If (_tapCount >= 5) {
      _tapCount = 0;

      Navigator.push(
        Context,
        MaterialPageRoute(
          Builder: (_) => const AdminDashboard(),
        ),
      );

      ScaffoldMessenger.of(context).showSnackBar(
        Const SnackBar(
          Content: Text(‘Admin Access Granted’),
          backgroundColor: Colors.green,
        ),
      );
}
  }

  // ---------------------------------------------------------------------------
  // GEMINI
  // ---------------------------------------------------------------------------

  Void _showGeminiChat() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _GeminiChatSheet(),
);
  }

  Void _showFlashcards(String subject) {
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
Try {
      DateTime? Date;

      If (timestamp is Timestamp) {
        Date = timestamp.toDate();
      } else if (timestamp is DateTime) {
        Date = timestamp;
      }

      If (date == null) {
        Return ‘’;
      }

      Return DateFormat(
        ‘dd MMM yyyy, hh:mm a’,
      ).format(date);
} catch € {
      Return ‘’;
}
  }

  String _formatBytes(dynamic value) {
Int bytes = 0;

If (value is num) {
      Bytes = value.toInt();
} else {
      Bytes = int.tryParse(
            Value?.toString() ?? ‘’,
          ) ??
          0;
}

If (bytes < 1024) {
      Return ‘$bytes B’;
}

If (bytes < 1048576) {
      Return ‘${(bytes / 1024).toStringAsFixed(1)} KB’;
}

If (bytes < 1073741824) {
      Return ‘${(bytes / 1048576).toStringAsFixed(1)} MB’;
}

Return ‘${(bytes / 1073741824).toStringAsFixed(1)} GB’;
  }

  Color _getCardColor(String course) {
Final int index =
        Course.hashCode % _cardColors.length;

Return _cardColors[index.abs()];
  }

  IconData _getFileIcon(String url) {
Final String lower =
        url.toLowerCase();

if (lower.contains(‘.pdf’)) {
      return Icons.picture_as_pdf;
}

If (lower.contains(‘.jpg’) ||
        Lower.contains(‘.jpeg’) ||
        Lower.contains(‘.png’) ||
        Lower.contains(‘.gif’) ||
        Lower.contains(‘.webp’)) {
      Return Icons.image;
}

If (lower.contains(‘.mp4’) ||
        Lower.contains(‘.mov’) ||
        Lower.contains(‘.avi’)) {
      Return Icons.video_file;
}

If (lower.contains(‘.doc’) ||
        Lower.contains(‘.docx’)) {
      Return Icons.description;
}

If (lower.contains(‘.xls’) ||
        Lower.contains(‘.xlsx’)) {
      Return Icons.table_chart;
}

If (lower.contains(‘.ppt’) ||
        Lower.contains(‘.pptx’)) {
      Return Icons.slideshow;
}

Return Icons.insert_drive_file;
  }

  // ---------------------------------------------------------------------------
  // MY UPLOADS VIEW
  // -----------------------------------------------------------------------------

  Widget _buildMyUploadsView(
    List<QueryDocumentSnapshot> approvedDocs,
Color primaryGreen,
  ) {
Return StreamBuilder<QuerySnapshot>(
      Stream: _firestore
          .collection(‘resources_pending’)
          .orderBy(
            ‘uploadedAt’,
            Descending: true,
          )
          .snapshots(),
      Builder: (context, pendingSnap) {
        Final List<_MyUploadItem> uploads = [];

        // APPROVED RESOURCES
        For (final QueryDocumentSnapshot doc
            In approvedDocs) {
          If (_isMyUpload(doc)) {
            Uploads.add(
              _MyUploadItem(
                Document: doc,
                isPendingCollection: false,
              ),
            );
          }
        }

        // PENDING / REJECTED RESOURCES
        If (pendingSnap.hasData) {
          For (final QueryDocumentSnapshot doc
              In pendingSnap.data!.docs) {
            If (_isMyUpload(doc)) {
              Uploads.add(
                _MyUploadItem(
                  Document: doc,
                  isPendingCollection: true,
                ),
              );
            }
          }
        }

        // Remove duplicate documents.
        Final Set<String> seenKeys = {};
        Uploads.removeWhere((item) {
          Final String key =
              ‘${item.isPendingCollection ? ‘pending’ : ‘approved’}_${item.document.id}’;

          If (seenKeys.contains(key)) {
            Return true;
          }

          seenKeys.add(key);
          return false;
        });

        // Sort newest first.
        Uploads.sort((a, b) {
          Final dynamic aData = a.document.data();
          Final dynamic bData = b.document.data();

          DateTime? aDate;
          DateTime? bDate;

          If (aData is Map &&
              aData[‘uploadedAt’] is Timestamp) {
            aDate =
                (aData[‘uploadedAt’] as Timestamp).toDate();
          }

          If (bData is Map &&
              bData[‘uploadedAt’] is Timestamp) {
            bDate =
                (bData[‘uploadedAt’] as Timestamp).toDate();
          }

          If (aDate == null && bDate == null) {
            Return 0;
          }

          If (aDate == null) {
            Return 1;
          }

          If (bDate == null) {
            Return -1;
          }

          Return bDate.compareTo(aDate);
        });

        If (uploads.isEmpty) {
          Return Center(
            Child: SingleChildScrollView(
              Child: Column(
                mainAxisAlignment:
                    MainAxisAlignment.center,
                Children: [
                  Icon(
                    Icons.cloud_upload,
                    Size: 80,
                    Color: Colors.grey.shade400,
                  ),
                  Const SizedBox(height: 16),
                  Text(
                    ‘No uploads yet’,
                    Style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Const SizedBox(height: 8),
                  Text(
                    ‘Files you upload will appear here.’,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      color: Colors.grey,
                    ),
                  ),
                  Const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        Context,
                        MaterialPageRoute(
                          Builder: (_) =>
                              Const StudentUploadScreen(),
                        ),
                      );
                    },
                    Icon: const Icon(
                      Icons.upload_file,
                    ),
                    Label: const Text(
                      ‘Upload a File’,
                    ),
                    Style: ElevatedButton.styleFrom(
                      backgroundColor:
                          primaryGreen,
                      foregroundColor:
                          Colors.white,
                    ),
                  ),
                  Const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: myUploads.isEmpty
                        ? null
                        : _clearUploadHistory,
                    Icon: const Icon(
                      Icons.delete_outline,
                    ),
                    Label: const Text(
                      ‘Clear History’,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        Return Column(
          Children: [
            Padding(
              Padding: const EdgeInsets.symmetric(
                Horizontal: 16,
                Vertical: 10,
              ),
              Child: Row(
                Children: [
                  Expanded(
                    Child: Text(
                      ‘My Uploads (${uploads.length})’,
                      Style: GoogleFonts.poppins(
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _clearUploadHistory,
                    icon: const Icon(
                      Icons.delete_outline,
                      Size: 18,
                    ),
                    Label: const Text(‘Clear’),
                  ),
                ],
              ),
            ),
            Expanded(
              Child: ListView.builder(
                Padding: const EdgeInsets.only(
                  Bottom: 90,
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

                  Final Map<String, dynamic> data =
                      Map<String, dynamic>.from(
                    rawData,
                  );

                  Final String status =
                      _getUploadStatus(
                    Doc,
                    isPendingCollection:
                        item.isPendingCollection,
                  );

                  Final Color statusColor =
                      _getStatusColor(status);

                  Final String title =
                      Data[‘title’]?.toString() ??
                          Data[‘fileName’]?.toString() ??
                          ‘Uploaded File’;

                  Final String fileUrl =
                      Data[‘fileUrl’]?.toString() ??
                          Data[‘url’]?.toString() ??
                          ‘’;

                  Final String course =
                      Data[‘course’]?.toString() ??
                          ‘Unknown Subject’;

                  Final String examType =
                      Data[‘examType’]?.toString() ??
                          ‘Resource’;

                  Return Card(
                    Margin: const EdgeInsets.symmetric(
                      Horizontal: 12,
                      Vertical: 6,
                    ),
                    Elevation: 2,
                    Shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(14),
                    ),
                    Child: Padding(
                      Padding:
                          Const EdgeInsets.all(12),
                      Child: Column(
                        Children: [
                          Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            Children: [
                              Container(
                                Padding:
                                    Const EdgeInsets.all(
                                  10,
                                ),
                                Decoration:
                                    BoxDecoration(
                                  Color: statusColor
                                      .withOpacity(
                                    0.12,
                                  ),
                                  borderRadius:
                                      BorderRadius
                                          .circular(
                                    12,
                                  ),
                                ),
                                Child: Icon(
                                  _getFileIcon(
                                    fileUrl,
                                  ),
                                  Color:
                                      statusColor,
                                  size: 28,
                                ),
                              ),
                              Const SizedBox(
                                Width: 12,
                              ),
                              Expanded(
                                Child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment
                                          .start,
                                  Children: [
                                    Text(
                                      Title,
                                      maxLines: 2,
                                      overflow:
                                          TextOverflow
                                              .ellipsis,
                                      Style:
                                          GoogleFonts
                                              .poppins(
                                        fontWeight:
                                            FontWeight
                                                .w600,
                                        fontSize: 15,
                                      ),
                                    ),
                                    Const SizedBox(
                                      Height: 5,
                                    ),
                                    Text(
                                      ‘$course • $examType’,
                                      maxLines: 2,
                                      overflow:
                                          TextOverflow
                                              .ellipsis,
                                      Style:
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
                          Const SizedBox(
                            Height: 10,
                          ),

                          // STATUS TAG
                          Row(
                            Children: [
                              Container(
                                Padding:
                                    Const EdgeInsets
                                        .symmetric(
                                  Horizontal: 10,
                                  Vertical: 5,
                                ),
                                Decoration:
                                    BoxDecoration(
                                  Color: statusColor
                                      .withOpacity(
                                    0.12,
                                  ),
                                  borderRadius:
                                      BorderRadius
                                          .circular(
                                    20,
                                  ),
                                  Border: Border.all(
                                    Color: statusColor
                                        .withOpacity(
                                      0.35,
                                    ),
                                  ),
                                ),
                                Child: Row(
                                  mainAxisSize:
                                      MainAxisSize.min,
                                  Children: [
                                    Icon(
                                      _getStatusIcon(
                                        Status,
                                      ),
                                      Size: 15,
                                      Color:
                                          statusColor,
                                    ),
                                    Const SizedBox(
                                      Width: 5,
                                    ),
                                    Text(
                                      Status,
                                      Style:
                                          GoogleFonts
                                              .poppins(
                                        Color:
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
                              Const Spacer(),
                              If (fileUrl.isNotEmpty)
                                IconButton(
                                  Tooltip:
                                      ‘Open file’,
                                  Icon: Icon(
                                    Icons
                                        .open_in_new,
                                    Color:
                                        primaryGreen,
                                  ),
                                  onPressed: () =>
                                      _openResource(
                                    Doc.id,
                                    fileUrl,
                                    title,
                                  ),
                                ),
                            ],
                          ),

                          Const Divider(
                            Height: 18,
                          ),

                          Row(
                            Children: [
                              Const Icon(
                                Icons
                                    .calendar_today,
                                Size: 13,
                                Color: Colors.grey,
                              ),
                              Const SizedBox(
                                Width: 5,
                              ),
                              Expanded(
                                Child: Text(
                                  _formatDate(
                                    Data[
                                        ‘uploadedAt’],
                                  ),
                                  Style:
                                      GoogleFonts
                                          .poppins(
                                    fontSize: 10,
                                    color:
                                        Colors.grey,
                                  ),
                                ),
                              ),
                              If (data[
                                      ‘fileSize’] !=
                                  Null) …[
                                Const Icon(
                                  Icons.data_object,
                                  Size: 13,
                                  Color: Colors.grey,
                                ),
                                Const SizedBox(
                                  Width: 5,
                                ),
                                Text(
                                  _formatBytes(
                                    Data[
                                        ‘fileSize’],
                                  ),
                                  Style:
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
Const Color primaryGreen =
        Color(0xFF00C896);

Const Color secondaryBlue =
        Color(0xFF3B82F6);

Final bool isDark =
        _themeMode == ‘dark’;

Return StreamBuilder<DocumentSnapshot>(
      Stream: _firestore
          .collection(‘settings’)
          .doc(‘app’)
          .snapshots(),
      Builder: (
        Context,
        settingsSnap,
      ) {
        List<String> liveSubjects = [
          ‘All’,
          ‘Maths’,
          ‘Physics’,
          ‘Chemistry’,
          ‘Biology’,
          ‘Favorites’,
          ‘Recent’,
          ‘My Uploads’,
        ];

        If (settingsSnap.hasData &&
            settingsSnap.data!.exists) {
          final dynamic rawSettings =
              settingsSnap.data!.data();

          if (rawSettings is Map) {
            final dynamic rawSubjects =
                rawSettings[‘subjects’];

            if (rawSubjects is List) {
              final List<String> dbSubjects =
                  rawSubjects
                      .map(
                        € => e.toString(),
                      )
                      .where(
                        € => e.isNotEmpty,
                      )
                      .toList();

              liveSubjects = [
                ‘All’,
                …dbSubjects,
                ‘Favorites’,
                ‘Recent’,
                ‘My Uploads’,
              ];
            }
          }
        }

        If (!liveSubjects.contains(
          selectedCourse,
        )) {
          selectedCourse = ‘All’;
        }

        Return Theme(
          Data: ThemeData(
            Brightness: isDark
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
          Child: Scaffold(
            appBar: AppBar(
              title: GestureDetector(
                onTap: _handleHeaderTap,
                child: Text(
                  ‘ExamHook’,
                  Style: GoogleFonts.poppins(
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
                  Tooltip: ‘Ask AI’,
                  Icon: const Icon(
                    Icons.smart_toy,
                  ),
                  onPressed:
                      _showGeminiChat,
                ),

                // UPLOAD APPBAR BUTTON REMOVED

                IconButton(
                  Tooltip: ‘Request Notes’,
                  Icon: const Icon(
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

            Drawer: Drawer(
              Child: Column(
                Children: [
                  DrawerHeader(
                    Decoration:
                        Const BoxDecoration(
                      Color: Color(0xFF1E293B),
                    ),
                    Child: Column(
                      mainAxisAlignment:
                          MainAxisAlignment.center,
                      Children: [
                        GestureDetector(
                          onTap:
                              _handleHeaderTap,
                          Child:
                              Const Icon(
                            Icons.school,
                            Size: 60,
                            Color: Colors.white,
                          ),
                        ),
                        Const SizedBox(
                          Height: 10,
                        ),
                        Text(
                          ‘ExamHook’,
                          Style:
                              GoogleFonts.poppins(
                            Color:
                                Colors.white,
                            fontSize: 22,
                            fontWeight:
                                FontWeight
                                    .bold,
                          ),
                        ),
                        Text(
                          ‘AI + Resources’,
                          Style:
                              GoogleFonts.poppins(
                            Color:
                                Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),

                  Padding(
                    Padding:
                        Const EdgeInsets.symmetric(
                      Horizontal: 16,
                      Vertical: 8,
                    ),
                    Child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment
                              .start,
                      Children: [
                        Text(
                          ‘Theme’,
                          Style:
                              GoogleFonts.poppins(
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                        Const SizedBox(
                          Height: 8,
                        ),
                        SegmentedButton<String>(
                          Segments: const [
                            ButtonSegment(
                              Value: ‘light’,
                              Label:
                                  Text(‘Light’),
                              Icon: Icon(
                                Icons.light_mode,
                              ),
                            ),
                            ButtonSegment(
                              Value: ‘dark’,
                              Label:
                                  Text(‘Dark’),
                              Icon: Icon(
                                Icons.dark_mode,
                              ),
                            ),
                          ],
                          Selected: {
                            _themeMode,
                          },
                          onSelectionChanged:
                              (newSelection) {
                            If (newSelection
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

                  Const Divider(),

                  // AI
                  ListTile(
                    Leading: const Icon(
                      Icons.smart_toy,
                      Color:
                          primaryGreen,
                    ),
                    Title: Text(
                      ‘Ask ExamHook AI’,
                      Style:
                          GoogleFonts.poppins(),
                    ),
                    onTap: () {
                      Navigator.pop(
                        Context,
                      );
                      _showGeminiChat();
                    },
                  ),

                  // FLASHCARDS
                  ListTile(
                    Leading: const Icon(
                      Icons.quiz,
                      Color:
                          primaryGreen,
                    ),
                    Title: Text(
                      ‘AI Flashcards’,
                      Style:
                          GoogleFonts.poppins(),
                    ),
                    onTap: () {
                      Navigator.pop(
                        Context,
                      );
                      _showFlashcards(
                        ‘General Knowledge’,
                      );
                    },
                  ),

                  // DRAWER UPLOAD OPTION REMOVED

                  Expanded(
                    Child:
                        ListView.builder(
                      itemCount:
                          liveSubjects.length,
                      itemBuilder:
                          (context, index) {
                        Final String subject =
                            liveSubjects[
                                index];

                        IconData icon =
                            Icons.book;

                        If (subject ==
                            ‘Favorites’) {
                          Icon =
                              Icons.bookmark;
                        }

                        If (subject ==
                            ‘Recent’) {
                          Icon =
                              Icons.history;
                        }

                        If (subject ==
                            ‘My Uploads’) {
                          Icon =
                              Icons.cloud_upload;
                        }

                        Final bool isNormalSubject =
                            Subject !=
                                ‘All’ &&
                            Subject !=
                                ‘Favorites’ &&
                            Subject !=
                                ‘Recent’ &&
                            Subject !=
                                ‘My Uploads’;

                        Return ListTile(
                          Leading: Icon(
                            Icon,
                            Color:
                                primaryGreen,
                          ),
                          Title: Text(
                            Subject,
                            Style:
                                GoogleFonts.poppins(),
                          ),
                          Trailing:
                              isNormalSubject
                                  ? IconButton(
                                      Icon:
                                          Const Icon(
                                        Icons.quiz,
                                        Size: 18,
                                      ),
                                      onPressed:
                                          () =>
                                              _showFlashcards(
                                        Subject,
                                      ),
                                    )
                                  : null,
                          Selected:
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
                              Context,
                            );
                          },
                        );
                      },
                    ),
                  ),

                  ListTile(
                    Leading: const Icon(
                      Icons.description,
                      Color:
                          primaryGreen,
                    ),
                    Title: Text(
                      ‘Terms & Conditions’,
                      Style:
                          GoogleFonts.poppins(),
                    ),
                    onTap:
                        _showTermsDialog,
                  ),
                ],
              ),
            ),

            // -----------------------------------------------------------------
            // FAB – ONLY UPLOAD METHOD
            // -----------------------------------------------------------------

            floatingActionButton:
                FloatingActionButton.extended(
              onPressed: () {
                Navigator.push(
                  Context,
                  MaterialPageRoute(
                    Builder: (_) =>
                        Const StudentUploadScreen(),
                  ),
                );
              },
              backgroundColor:
                  primaryGreen,
              icon: const Icon(
                Icons.add,
              ),
              Label: Text(
                ‘Upload’,
                Style:
                    GoogleFonts.poppins(
                  fontWeight:
                      FontWeight.w600,
                ),
              ),
            ),

            // -----------------------------------------------------------------
            // BODY
            // -----------------------------------------------------------------

            Body: Column(
              Children: [
                Padding(
                  Padding:
                      Const EdgeInsets.all(
                    12,
                  ),
                  Child: TextField(
                    Controller:
                        _searchController,
                    Decoration:
                        InputDecoration(
                      hintText:
                          ‘Search resources…’,
                      prefixIcon:
                          const Icon(
                        Icons.search,
                      ),
                      Border:
                          OutlineInputBorder(
                        borderRadius:
                            BorderRadius
                                .circular(
                          12,
                        ),
                      ),
                      Filled: true,
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

                If (selectedCourse !=
                    ‘My Uploads’)
                  Padding(
                    Padding:
                        Const EdgeInsets
                            .symmetric(
                      Horizontal: 12,
                    ),
                    Child:
                        DropdownButtonFormField<
                            String>(
                      Value:
                          selectedCourse,
                      decoration:
                          InputDecoration(
                        labelText:
                            ‘Subject’,
                        Border:
                            OutlineInputBorder(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            12,
                          ),
                        ),
                      ),
                      Items: liveSubjects
                          .map(
                            (
                              E,
                            ) =>
                                DropdownMenuItem<
                                    String>(
                              Value: e,
                              Child:
                                  Text€,
                            ),
                          )
                          .toList(),
                      onChanged:
                          (val) {
                        If (val ==
                            Null) {
                          Return;
                        }

                        setState(() {
                          selectedCourse =
                              val;
                        });
                      },
                    ),
                  ),

                Const SizedBox(
                  Height: 10,
                ),

                Expanded(
                  Child:
                      StreamBuilder<
                          QuerySnapshot>(
                    Stream: _firestore
                        .collection(
                            ‘resources’)
                        .orderBy(
                          ‘uploadedAt’,
                          Descending:
                              True,
                        )
                        .snapshots(),
                    Builder: (
                      Context,
                      Snapshot,
                    ) {
                      If (snapshot
                              .connectionState ==
                          ConnectionState
                              .waiting) {
                        Return const Center(
                          Child:
                              CircularProgressIndicator(),
                        );
                      }

                      If (snapshot.hasError) {
                        Return Center(
                          Child:
                              Padding(
                            Padding:
                                Const EdgeInsets
                                    .all(
                              20,
                            ),
                            Child: Text(
                              ‘Error: ${snapshot.error}’,
                            ),
                          ),
                        );
                      }

                      Final List<
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

                      If (selectedCourse ==
                          ‘My Uploads’) {
                        Return _buildMyUploadsView(
                          allApprovedDocs,
                          primaryGreen,
                        );
                      }

                      // -------------------------------------------------------
                      // NORMAL RESOURCES
                      // -------------------------------------------------------

                      List<
                              QueryDocumentSnapshot>
                          Docs =
                          List.from(
                        allApprovedDocs,
                      );

                      If (selectedCourse ==
                          ‘Favorites’) {
                        Docs = docs
                            .where(
                              (d) =>
                                  favoriteDocs
                                      .contains(
                                d.id,
                              ),
                            )
                            .toList();
                      } else if (selectedCourse ==
                          ‘Recent’) {
                        Docs = docs
                            .where(
                              (d) =>
                                  recentlyViewed
                                      .contains(
                                d.id,
                              ),
                            )
                            .toList();
                      } else if (selectedCourse !=
                          ‘All’) {
                        Docs = docs
                            .where(
                              (d) {
                                Final dynamic raw =
                                    d.data();

                                if (raw is! Map) {
                                  return false;
                                }

                                Return raw[
                                            ‘course’]
                                        ?.toString() ==
                                    selectedCourse;
                              },
                            )
                            .toList();
                      }

                      If (searchQuery
                          .isNotEmpty) {
                        Docs = docs
                            .where(
                              (d) {
                                Final dynamic raw =
                                    d.data();

                                if (raw is! Map) {
                                  return false;
                                }

                                Final Map<String,
                                        Dynamic>
                                    Data =
                                    Map<String,
                                        Dynamic>.from(
                                  Raw,
                                );

                                Final String title =
                                    Data[
                                                ‘title’]
                                            ?.toString()
                                            .toLowerCase() ??
                                        ‘’;

                                Final String course =
                                    Data[
                                                ‘course’]
                                            ?.toString()
                                            .toLowerCase() ??
                                        ‘’;

                                Final String fileName =
                                    Data[
                                                ‘fileName’]
                                            ?.toString()
                                            .toLowerCase() ??
                                        ‘’;

                                Return title.contains(
                                      searchQuery,
                                    ) ||
                                    Course.contains(
                                      searchQuery,
                                    ) ||
                                    fileName.contains(
                                      searchQuery,
                                    );
                              },
                            )
                            .toList();
                      }

                      If (docs.isEmpty) {
                        Return Center(
                          Child:
                              Padding(
                            Padding:
                                Const EdgeInsets
                                    .all(
                              24,
                            ),
                            Child:
                                Column(
                              mainAxisAlignment:
                                  MainAxisAlignment
                                      .center,
                              Children: [
                                Icon(
                                  Icons
                                      .folder_open,
                                  Size: 100,
                                  Color:
                                      primaryGreen
                                          .withOpacity(
                                    0.5,
                                  ),
                                ),
                                Const SizedBox(
                                  Height: 20,
                                ),
                                Text(
                                  ‘No resources yet’,
                                  Style:
                                      GoogleFonts
                                          .poppins(
                                    fontSize:
                                        22,
                                    fontWeight:
                                        FontWeight
                                            .bold,
                                  ),
                                ),
                                Const SizedBox(
                                  Height: 8,
                                ),
                                Text(
                                  ‘Be the first to upload or ask AI’,
                                  textAlign:
                                      TextAlign
                                          .center,
                                  Style:
                                      GoogleFonts
                                          .poppins(
                                    fontSize:
                                        14,
                                    Color:
                                        Colors
                                            .grey,
                                  ),
                                ),
                                Const SizedBox(
                                  Height: 20,
                                ),
                                ElevatedButton
                                    .icon(
                                  onPressed:
                                      _showGeminiChat,
                                  Icon:
                                      Const Icon(
                                    Icons
                                        .smart_toy,
                                  ),
                                  Label:
                                      Const Text(
                                    ‘Ask AI’,
                                  ),
                                  Style:
                                      ElevatedButton
                                          .styleFrom(
                                    backgroundColor:
                                        primaryGreen,
                                    foregroundColor:
                                        Colors
                                            .white,
                                    Shape:
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

                      Return ListView.builder(
                        Padding:
                            Const EdgeInsets
                                .only(
                          Bottom: 90,
                        ),
                        itemCount:
                            docs.length,
                        itemBuilder:
                            (context, index) {
                          Final QueryDocumentSnapshot
                              Doc =
                              Docs[index];

                          Final dynamic raw =
                              Doc.data();

                          If (raw is! Map) {
                            Return const SizedBox
                                .shrink();
                          }

                          Final Map<String,
                                  Dynamic>
                              Data =
                              Map<String,
                                  Dynamic>.from(
                            Raw,
                          );

                          Final String docId =
                              Doc.id;

                          Final String title =
                              Data[‘title’]
                                      ?.toString() ??
                                  ‘No Title’;

                          Final String fileUrl =
                              Data[‘fileUrl’]
                                      ?.toString() ??
                                  ‘’;

                          Final String course =
                              Data[‘course’]
                                      ?.toString() ??
                                  ‘’;

                          Final String examType =
                              Data[‘examType’]
                                      ?.toString() ??
                                  ‘’;

                          Final bool isLiked =
                              likedDocs
                                  .contains(
                            docId,
                          );

                          Final bool isRated =
                              ratedDocs
                                  .contains(
                            docId,
                          );

                          Final bool isFav =
                              favoriteDocs
                                  .contains(
                            docId,
                          );

                          Final Color cardColor =
                              _getCardColor(
                            Course,
                          );

                          Return Card(
                            Margin:
                                Const EdgeInsets
                                    .symmetric(
                              Horizontal:
                                  12,
                              Vertical:
                                  8,
                            ),
                            Elevation: 4,
                            Shape:
                                RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius
                                      .circular(
                                20,
                              ),
                            ),
                            Child:
                                Container(
                              Decoration:
                                  BoxDecoration(
                                borderRadius:
                                    BorderRadius
                                        .circular(
                                  20,
                                ),
                                Gradient:
                                    LinearGradient(
                                  Colors: [
                                    cardColor
                                        .withOpacity(
                                      0.1,
                                    ),
                                    cardColor
                                        .withOpacity(
                                      0.02,
                                    ),
                                  ],
                                  Begin:
                                      Alignment
                                          .topLeft,
                                  End:
                                      Alignment
                                          .bottomRight,
                                ),
                                Border:
                                    Border.all(
                                  Color: cardColor
                                      .withOpacity(
                                    0.3,
                                  ),
                                ),
                              ),
                              Child:
                                  Padding(
                                Padding:
                                    Const EdgeInsets
                                        .all(
                                  14,
                                ),
                                Child:
                                    Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment
                                          .start,
                                  Children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment
                                              .start,
                                      Children: [
                                        Container(
                                          Padding:
                                              Const EdgeInsets
                                                  .all(
                                            10,
                                          ),
                                          Decoration:
                                              BoxDecoration(
                                            Color: cardColor
                                                .withOpacity(
                                              0.2,
                                            ),
                                            borderRadius:
                                                BorderRadius
                                                    .circular(
                                              12,
                                            ),
                                          ),
                                          Child:
                                              Icon(
                                            _getFileIcon(
                                              fileUrl,
                                            ),
                                            Color:
                                                cardColor,
                                            size:
                                                28,
                                          ),
                                        ),
                                        Const SizedBox(
                                          Width:
                                              12,
                                        ),
                                        Expanded(
                                          Child:
                                              Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment
                                                    .start,
                                            Children: [
                                              Text(
                                                Title,
                                                Style:
                                                    GoogleFonts.poppins(
                                                  fontWeight:
                                                      FontWeight.w600,
                                                  fontSize:
                                                      16,
                                                ),
                                              ),
                                              Const SizedBox(
                                                Height:
                                                    4,
                                              ),
                                              Container(
                                                Padding:
                                                    Const EdgeInsets.symmetric(
                                                  Horizontal:
                                                      8,
                                                  Vertical:
                                                      2,
                                                ),
                                                Decoration:
                                                    BoxDecoration(
                                                  Color:
                                                      cardColor,
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                    8,
                                                  ),
                                                ),
                                                Child:
                                                    Text(
                                                  ‘$course • $examType’,
                                                  Style:
                                                      GoogleFonts.poppins(
                                                    fontSize:
                                                        11,
                                                    Color:
                                                        Colors.white,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          Icon:
                                              Icon(
                                            isFav
                                                ? Icons.bookmark
                                                : Icons.bookmark_border,
                                            Color:
                                                primaryGreen,
                                          ),
                                          onPressed:
                                              () =>
                                                  _toggleFavorite(
                                            docId,
                                          ),
                                        ),
                                        IconButton(
                                          Icon:
                                              Const Icon(
                                            Icons.share,
                                            Color:
                                                Colors.grey,
                                            Size:
                                                24,
                                          ),
                                          onPressed:
                                              () =>
                                                  _shareResource(
                                            Title,
                                            fileUrl,
                                          ),
                                        ),
                                        If (fileUrl
                                            .toLowerCase()
                                            .contains(
                                              ‘.pdf’,
                                            ))
                                          IconButton(
                                            Icon:
                                                Icon(
                                              Icons.quiz,
                                              Color:
                                                  primaryGreen,
                                            ),
                                            Tooltip:
                                                ‘Generate Flashcards’,
                                            onPressed:
                                                () =>
                                                    _generateFlashcardsFromPdf(
                                              fileUrl,
                                              title,
                                            ),
                                          ),
                                        IconButton(
                                          Icon:
                                              Const Icon(
                                            Icons.open_in_new,
                                            Color:
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
                                    Const SizedBox(
                                      Height:
                                          10,
                                    ),
                                    Row(
                                      Children: [
                                        Const Icon(
                                          Icons
                                              .calendar_today,
                                          Size:
                                              12,
                                          Color:
                                              Colors.grey,
                                        ),
                                        Const SizedBox(
                                          Width:
                                              4,
                                        ),
                                        Text(
                                          _formatDate(
                                            Data[
                                                ‘uploadedAt’],
                                          ),
                                          Style:
                                              GoogleFonts.poppins(
                                            fontSize:
                                                11,
                                          ),
                                        ),
                                        Const SizedBox(
                                          Width:
                                              12,
                                        ),
                                        Const Icon(
                                          Icons
                                              .data_object,
                                          Size:
                                              12,
                                          Color:
                                              Colors.grey,
                                        ),
                                        Const SizedBox(
                                          Width:
                                              4,
                                        ),
                                        Text(
                                          _formatBytes(
                                            Data[
                                                ‘fileSize’],
                                          ),
                                          Style:
                                              GoogleFonts.poppins(
                                            fontSize:
                                                11,
                                          ),
                                        ),
                                      ],
                                    ),
                                    Const SizedBox(
                                      Height:
                                          10,
                                    ),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment
                                              .spaceBetween,
                                      Children: [
                                        Row(
                                          Children: [
                                            IconButton(
                                              Icon:
                                                  Icon(
                                                Icons.favorite,
                                                Color:
                                                    isLiked
                                                        ? Colors.red
                                                        : Colors.grey,
                                                Size:
                                                    20,
                                              ),
                                              onPressed:
                                                  () =>
                                                      _likeResource(
                                                docId,
                                              ),
                                            ),
                                            Text(
                                              ‘${data[‘likes’] ?? 0}’,
                                              Style:
                                                  GoogleFonts.poppins(
                                                fontSize:
                                                    12,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Row(
                                          Children: [
                                            Const Icon(
                                              Icons.star,
                                              Color:
                                                  Colors.amber,
                                              Size:
                                                  20,
                                            ),
                                            Text(
                                              ‘ ${(data[‘rating’] is num ? (data[‘rating’] as num).toDouble() : 0.0).toStringAsFixed(1)}’,
                                              Style:
                                                  GoogleFonts.poppins(
                                                fontSize:
                                                    12,
                                              ),
                                            ),
                                            PopupMenuButton<
                                                Double>(
                                              Enabled:
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
                                                              E,
                                                            ) =>
                                                                PopupMenuItem<double>(
                                                              Value:
                                                                  E,
                                                              Child:
                                                                  Text(
                                                                ‘${e.toInt()} Star’,
                                                              ),
                                                            ),
                                                          )
                                                          .toList(),
                                              Child:
                                                  Icon(
                                                Icons.rate_review,
                                                Size:
                                                    20,
                                                Color:
                                                    isRated
                                                        ? Colors.grey
                                                        : Colors.black,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Row(
                                          Children: [
                                            Const Icon(
                                              Icons.download,
                                              Color:
                                                  Colors.blue,
                                              Size:
                                                  20,
                                            ),
                                            Text(
                                              ‘ ${data[‘downloads’] ?? 0}’,
                                              Style:
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

Class _MyUploadItem {
  Final QueryDocumentSnapshot document;
  Final bool isPendingCollection;

  Const _MyUploadItem({
Required this.document,
Required this.isPendingCollection,
  });
}

// -----------------------------------------------------------------------------
// FLASHCARD DIALOG
// -----------------------------------------------------------------------------

Class _FlashcardDialog extends StatefulWidget {
  Final String subject;

  Const _FlashcardDialog({
Required this.subject,
  });

  @override
  State<_FlashcardDialog> createState() =>
      _FlashcardDialogState();
}

Class _FlashcardDialogState
Extends State<_FlashcardDialog> {
  List<Flashcard> _cards = [];
  Bool _isLoading = true;

  Int _index = 0;
  Bool _showAnswer = false;

  @override
  Void initState() {
Super.initState();
_generate();
  }

  Future<void> _generate() async {
Try {
      Final String prompt =
          ‘’’
Generate 10 flashcards for ${widget.subject} for high school exams.

Rules:
1. Return ONLY a valid JSON array. No markdown, no asterisks, no explanation.
2. Format: [{“q”: “question”, “a”: “answer”}]
3. For formulas write them in plain LaTeX without \$ signs. Example: F = ma, E = mc^2, \\frac{a}{b}, x^2
4. Keep answers short, max 15 words.
‘’’;

      Final GenerateContentResponse response =
          Await model.generateContent([
        Content.text(prompt),
      ]);

      String text = response.text ?? ‘’;

      Text = text
          .replaceAll(‘```json’, ‘’)
          .replaceAll(‘```’, ‘’)
          .trim();

      Final dynamic decoded = jsonDecode(text);

      If (decoded is! List) {
        Throw Exception(
          ‘Invalid AI response’,
        );
      }

      Final List<Flashcard> cards = decoded
          .whereType<Map>()
          .map(
            € => Flashcard(
              Question:
                  E[‘q’]?.toString() ?? ‘’,
              Answer:
                  E[‘a’]?.toString() ?? ‘’,
            ),
          )
          .where(
            (card) =>
                Card.question.isNotEmpty &&
                Card.answer.isNotEmpty,
          )
          .toList();

      If (!mounted) return;

      setState(() {
        _cards = cards;
        _isLoading = false;
      });
} catch € {
      If (!mounted) return;

      setState(() {
        _isLoading = false;
      });
}
  }

  @override
  Widget build(BuildContext context) {
Return Dialog(
      Child: Container(
        Height: 400,
        Padding: const EdgeInsets.all(16),
        Child: _isLoading
            ? const Center(
                Child:
                    CircularProgressIndicator(),
              )
            : _cards.isEmpty
                ? Center(
                    Child: Text(
                      ‘Could not generate flashcards.’,
                      Style:
                          GoogleFonts.poppins(),
                    ),
                  )
                : Column(
                    Children: [
                      Text(
                        ‘${widget.subject} Flashcards’,
                        Style:
                            GoogleFonts.poppins(
                          fontSize: 20,
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                      Const SizedBox(
                        Height: 20,
                      ),
                      Expanded(
                        Child:
                            GestureDetector(
                          onTap: () {
                            setState(() {
                              _showAnswer =
                                  !_showAnswer;
                            });
                          },
                          Child: Card(
                            Color:
                                Const Color(
                              0xFF00C896,
                            ),
                            Child: Center(
                              Child: Padding(
                                Padding:
                                    Const EdgeInsets
                                        .all(
                                  20,
                                ),
                                Child:
                                    _buildMathText(
                                  _showAnswer
                                      ? _cards[
                                          _index]
                                          .answer
                                      : _cards[
                                          _index]
                                          .question,
                                  Style:
                                      GoogleFonts
                                          .poppins(
                                    fontSize:
                                        22,
                                    Color:
                                        Colors
                                            .white,
                                  ),
                                  Align:
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
                        Children: [
                          TextButton(
                            onPressed:
                                _index > 0
                                    ? () {
                                        setState(
                                          () {
                                            _index--;
                                            _showAnswer =
                                                False;
                                          },
                                        );
                                      }
                                    : null,
                            Child:
                                Const Text(
                              ‘Prev’,
                            ),
                          ),
                          Text(
                            ‘${_index + 1}/${_cards.length}’,
                          ),
                          TextButton(
                            onPressed:
                                _index <
                                        _cards.length –
                                            1
                                    ? () {
                                        setState(
                                          () {
                                            _index++;
                                            _showAnswer =
                                                False;
                                          },
                                        );
                                      }
                                    : null,
                            Child:
                                Const Text(
                              ‘Next’,
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

Class _FlashcardDialogFromList
Extends StatefulWidget {
  Final List<Flashcard> cards;
  Final String title;

  Const _FlashcardDialogFromList({
Required this.cards,
Required this.title,
  });

  @override
  State<_FlashcardDialogFromList> createState() =>
      _FlashcardDialogFromListState();
}

Class _FlashcardDialogFromListState
Extends State<_FlashcardDialogFromList> {
  Int _index = 0;
  Bool _showAnswer = false;

  @override
  Widget build(BuildContext context) {
If (widget.cards.isEmpty) {
      Return const Dialog(
        Child: Padding(
          Padding: EdgeInsets.all(24),
          Child: Text(
            ‘No flashcards available.’,
          ),
        ),
      );
}

Return Dialog(
      Child: Container(
        Height: 400,
        Padding: const EdgeInsets.all(16),
        Child: Column(
          Children: [
            Text(
              ‘Flashcards from: ${widget.title}’,
              maxLines: 2,
              overflow:
                  TextOverflow.ellipsis,
              Style: GoogleFonts.poppins(
                fontSize: 18,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
            Const SizedBox(
              Height: 20,
            ),
            Expanded(
              Child: GestureDetector(
                onTap: () {
                  setState(() {
                    _showAnswer =
                        !_showAnswer;
                  });
                },
                Child: Card(
                  Color:
                      Const Color(0xFF00C896),
                  Child: Center(
                    Child: Padding(
                      Padding:
                          Const EdgeInsets
                              .all(
                        20,
                      ),
                      Child: _buildMathText(
                        _showAnswer
                            ? widget
                                .cards[
                                    _index]
                                .answer
                            : widget
                                .cards[
                                    _index]
                                .question,
                        Style:
                            GoogleFonts.poppins(
                          fontSize: 22,
                          color:
                              Colors.white,
                        ),
                        Align:
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
              Children: [
                TextButton(
                  onPressed:
                      _index > 0
                          ? () {
                              setState(
                                () {
                                  _index--;
                                  _showAnswer =
                                      False;
                                },
                              );
                            }
                          : null,
                  Child:
                      Const Text(‘Prev’),
                ),
                Text(
                  ‘${_index + 1}/${widget.cards.length}’,
                ),
                TextButton(
                  onPressed:
                      _index <
                              Widget.cards.length –
                                  1
                          ? () {
                              setState(
                                () {
                                  _index++;
                                  _showAnswer =
                                      False;
                                },
                              );
                            }
                          : null,
                  Child:
                      Const Text(‘Next’),
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

Class _GeminiChatSheet
Extends StatefulWidget {
  Const _GeminiChatSheet();

  @override
  State<_GeminiChatSheet> createState() =>
      _GeminiChatSheetState();
}

Class _GeminiChatSheetState
Extends State<_GeminiChatSheet> {
  Final TextEditingController _controller =
      TextEditingController();

  Final List<Map<String, String>> _chat =
      [];

  Bool _isLoading = false;

  Final ScrollController _scrollController =
      ScrollController();

  // Keys used to save the AI conversation.
  Static const String _chatStorageKey =
      ‘exam_hook_ai_chat’;

  Static const String _chatTimeKey =
      ‘exam_hook_ai_chat_time’;

  // Conversation lifetime.
  Static const Duration _chatLifetime =
      Duration(hours: 24);

  @override
  Void initState() {
Super.initState();
_loadChat();
  }

  @override
  Void dispose() {
_controller.dispose();
    _scrollController.dispose();
Super.dispose();
  }

  // ---------------------------------------------------------------------------
  // LOAD AI CHAT
  // ---------------------------------------------------------------------------

  Future<void> _loadChat() async {
Try {
      Final SharedPreferences prefs =
          Await SharedPreferences.getInstance();

      Final int? savedTime =
          Prefs.getInt(_chatTimeKey);

      Final List<String>? savedMessages =
          Prefs.getStringList(
        _chatStorageKey,
      );

      If (savedTime == null ||
          savedMessages == null ||
          savedMessages.isEmpty) {
        return;
      }

      Final DateTime savedAt =
          DateTime.fromMillisecondsSinceEpoch(
        savedTime,
      );

      Final Duration age =
          DateTime.now().difference(savedAt);

      // Automatically remove conversation after 24 hours.
      If (age >= _chatLifetime) {
        Await prefs.remove(_chatStorageKey);
        Await prefs.remove(_chatTimeKey);
        Return;
      }

      Final List<Map<String, String>>
          restoredChat = [];

      for (final String encoded
          in savedMessages) {
        try {
          final dynamic decoded =
              jsonDecode(encoded);

          if (decoded is Map) {
            final String role =
                decoded[‘role’]?.toString() ?? ‘’;

            final String text =
                decoded[‘text’]?.toString() ?? ‘’;

            if (role.isNotEmpty &&
                text.isNotEmpty) {
              restoredChat.add({
                ‘role’: role,
                ‘text’: text,
              });
            }
          }
        } catch € {
          debugPrint(
            ‘Could not restore AI message: $e’,
          );
        }
      }

      If (!mounted) return;

      setState(() {
        _chat.clear();
        _chat.addAll(restoredChat);
      });

      _scrollToBottom();
} catch € {
      debugPrint(
        ‘AI chat load error: $e’,
      );
}
  }

  // ---------------------------------------------------------------------------
  // SAVE AI CHAT
  // ---------------------------------------------------------------------------

  Future<void> _saveChat() async {
Try {
      Final SharedPreferences prefs =
          Await SharedPreferences.getInstance();

      Final List<String> encodedMessages =
          _chat.map((message) {
        Return jsonEncode({
          ‘role’: message[‘role’] ?? ‘’,
          ‘text’: message[‘text’] ?? ‘’,
        });
      }).toList();

      Await prefs.setStringList(
        _chatStorageKey,
        encodedMessages,
      );

      // Only set the timestamp if this conversation
      // does not already have one.
      If (!prefs.containsKey(_chatTimeKey)) {
        Await prefs.setInt(
          _chatTimeKey,
          DateTime.now()
              .millisecondsSinceEpoch,
        );
      }
} catch € {
      debugPrint(
        ‘AI chat save error: $e’,
      );
}
  }

  // ---------------------------------------------------------------------------
  // CLEAR EXPIRED CHAT
  // ---------------------------------------------------------------------------

  Future<void> _clearExpiredChatIfNeeded() async {
Try {
      Final SharedPreferences prefs =
          Await SharedPreferences.getInstance();

      Final int? savedTime =
          Prefs.getInt(_chatTimeKey);

      If (savedTime == null) {
        Return;
      }

      Final DateTime savedAt =
          DateTime.fromMillisecondsSinceEpoch(
        savedTime,
      );

      If (DateTime.now().difference(savedAt) >=
          _chatLifetime) {
        Await prefs.remove(_chatStorageKey);
        Await prefs.remove(_chatTimeKey);

        If (!mounted) return;

        setState(() {
          _chat.clear();
        });
      }
} catch € {
      debugPrint(
        ‘AI chat expiry error: $e’,
      );
}
  }

  // ---------------------------------------------------------------------------
  // SCROLL
  // ---------------------------------------------------------------------------

  Void _scrollToBottom() {
Future.delayed(
      Const Duration(milliseconds: 150),
      () {
        If (!_scrollController.hasClients) {
          Return;
        }

        _scrollController.animateTo(
          0,
          Duration:
              Const Duration(milliseconds: 200),
          Curve: Curves.easeOut,
        );
      },
);
  }

  // ---------------------------------------------------------------------------
  // ASK AI
  // ---------------------------------------------------------------------------

  Future<void> _ask() async {
Await _clearExpiredChatIfNeeded();

Final String question =
        _controller.text.trim();

If (question.isEmpty ||
        _isLoading) {
      Return;
}

If (!mounted) return;

setState(() {
      _chat.add({
        ‘role’: ‘user’,
        ‘text’: question,
      });

      _isLoading = true;
});

_controller.clear();

// Save immediately so the user message survives
// closing/reopening the AI sheet.
Await _saveChat();

Try {
      Final String prompt =
          ‘’’
You are ExamHook AI tutor for high school students in Zimbabwe.

Rules:
1. Do NOT use asterisks for bold or italic.
2. Use plain text with headings like “Definition:”
3. For formulas write them in plain LaTeX without \$ signs. Example: F = ma, E = mc^2, \\\\frac{a}{b}, x^2, \\\\sqrt{b^2 – 4ac}
4. Keep answers clear, short, with examples.

Question: $question
‘’’;

      Final GenerateContentResponse response =
          Await model.generateContent([
        Content.text(prompt),
      ]);

      If (!mounted) return;

      setState(() {
        _chat.add({
          ‘role’: ‘ai’,
          ‘text’:
              Response.text ?? ‘No answer’,
        });

        _isLoading = false;
      });

      Await _saveChat();

      _scrollToBottom();
} catch € {
      If (!mounted) return;

      setState(() {
        _chat.add({
          ‘role’: ‘ai’,
          ‘text’: ‘Error: $e’,
        });

        _isLoading = false;
      });

      Await _saveChat();

      _scrollToBottom();
}
  }

  // ---------------------------------------------------------------------------
  // BUILD AI CHAT
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
Return Container(
      Height:
          MediaQuery.of(context)
                  .size
                  .height *
              0.85,
      Padding:
          EdgeInsets.only(
        Bottom:
            MediaQuery.of(context)
                .viewInsets
                .bottom,
      ),
      Child: Column(
        Children: [
          AppBar(
            Title: Text(
              ‘Ask ExamHook AI’,
              Style:
                  GoogleFonts.poppins(),
            ),
            automaticallyImplyLeading:
                false,
            backgroundColor:
                const Color(0xFF00C896),
            actions: [
              // Clear AI conversation manually.
              IconButton(
                Tooltip: ‘Clear AI conversation’,
                Icon: const Icon(
                  Icons.delete_outline,
                ),
                onPressed: _chat.isEmpty
                    ? null
                    : () async {
                        Final bool? Confirmed =
                            Await showDialog<bool>(
                          Context: context,
                          Builder:
                              (dialogContext) {
                            Return AlertDialog(
                              Title: const Text(
                                ‘Clear conversation?’,
                              ),
                              Content:
                                  Const Text(
                                ‘This will remove the saved AI conversation.’,
                              ),
                              Actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(
                                    dialogContext,
                                    false,
                                  ),
                                  Child:
                                      Const Text(
                                    ‘Cancel’,
                                  ),
                                ),
                                ElevatedButton(
                                  onPressed: () =>
                                      Navigator.pop(
                                    dialogContext,
                                    true,
                                  ),
                                  Child:
                                      Const Text(
                                    ‘Clear’,
                                  ),
                                ),
                              ],
                            );
                          },
                        );

                        If (confirmed != true) {
                          Return;
                        }

                        Try {
                          Final SharedPreferences
                              Prefs =
                              Await SharedPreferences
                                  .getInstance();

                          Await prefs.remove(
                            _chatStorageKey,
                          );

                          Await prefs.remove(
                            _chatTimeKey,
                          );

                          If (!mounted) return;

                          setState(() {
                            _chat.clear();
                          });
                        } catch € {
                          debugPrint(
                            ‘Clear AI chat error: $e’,
                          );
                        }
                      },
              ),
            ],
          ),

          Expanded(
            Child:
                ListView.builder(
              Controller:
                  _scrollController,
              Reverse: true,
              Padding:
                  Const EdgeInsets
                      .all(12),
              itemCount:
                  _chat.length,
              itemBuilder:
                  (context, i) {
                Final Map<String, String>
                    Msg =
                    _chat[
                        _chat.length –
                            1 –
                            I];

                Final bool isUser =
                    Msg[‘role’] ==
                        ‘user’;

                Return Align(
                  Alignment: isUser
                      ? Alignment
                          .centerRight
                      : Alignment
                          .centerLeft,
                  Child:
                      Container(
                    Margin:
                        Const EdgeInsets
                            .symmetric(
                      Vertical: 4,
                    ),
                    Padding:
                        Const EdgeInsets
                            .all(12),
                    Constraints:
                        BoxConstraints(
                      maxWidth:
                          MediaQuery.of(
                                    Context,
                                  )
                                  .size
                                  .width *
                              0.8,
                    ),
                    Decoration:
                        BoxDecoration(
                      Color: isUser
                          ? const Color(
                              0xFF00C896,
                            )
                          : Colors
                              .grey
                              .shade300,
                      borderRadius:
                          BorderRadius
                              .circular(
                        16,
                      ),
                    ),
                    Child: isUser
                        ? Text(
                            Msg[‘text’] ??
                                ‘’,
                            Style:
                                GoogleFonts
                                    .poppins(
                              Color:
                                  Colors.white,
                              fontSize:
                                  15,
                            ),
                          )
                        : _buildMathText(
                            Msg[‘text’] ??
                                ‘’,
                            Style:
                                GoogleFonts
                                    .poppins(
                              Color:
                                  Colors.black,
                              fontSize:
                                  15,
                            ),
                            Align:
                                TextAlign
                                    .left,
                          ),
                  ),
                );
              },
            ),
          ),

          If (_isLoading)
            Const LinearProgressIndicator(
              minHeight: 2,
            ),

          Padding(
            Padding:
                Const EdgeInsets
                    .all(8),
            Child: Row(
              Children: [
                Expanded(
                  Child:
                      TextField(
                    Controller:
                        _controller,
                    onSubmitted:
                        (_) => _ask(),
                    textCapitalization:
                        TextCapitalization
                            .sentences,
                    Decoration:
                        InputDecoration(
                      hintText:
                          ‘Ask about Maths, Physics…’,
                      Border:
                          OutlineInputBorder(
                        borderRadius:
                            BorderRadius
                                .circular(
                          12,
                        ),
                      ),
                      contentPadding:
                          const EdgeInsets
                              .symmetric(
                        Horizontal:
                            12,
                        Vertical:
                            10,
                      ),
                    ),
                  ),
                ),
                Const SizedBox(
                  Width: 8,
                ),
                CircleAvatar(
                  backgroundColor:
                      const Color(
                    0xFF00C896,
                  ),
                  Child:
                      IconButton(
                    Icon:
                        Const Icon(
                      Icons.send,
                      Color:
                          Colors.white,
                      Size: 20,
                    ),
                    onPressed:
                        _ask,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
);
  }
}

