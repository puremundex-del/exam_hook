Import ‘package:flutter/material.dart’;
Import ‘package:supabase_flutter/supabase_flutter.dart’;
Import ‘package:cloud_firestore/cloud_firestore.dart’;
Import ‘package:google_fonts/google_fonts.dart’;
Import ‘package:uuid/uuid.dart’;
Import ‘package:file_picker/file_picker.dart’;
Import ‘dart:typed_data’;
Import ‘package:intl/intl.dart’;
Import ‘package:url_launcher/url_launcher.dart’;

Class AdminDashboard extends StatefulWidget {
  Const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

Class _AdminDashboardState extends State<AdminDashboard>
With SingleTickerProviderStateMixin {
  Late TabController _tabController;
  Final _formKey = GlobalKey<FormState>();
  Final _titleController = TextEditingController();
  Final _newSubjectController = TextEditingController();
  Final _searchController = TextEditingController();

  String _course = ‘Maths’;
  String _examType = ‘Notes’;
  Bool _isUploading = false;
  String _searchQuery = ‘’;

  Final supabase = Supabase.instance.client;
  Final firestore = FirebaseFirestore.instance;
  Final uuid = const Uuid();

  Uint8List? _fileBytes;
  String? _fileName;

  List<String> subjects = [‘Maths’, ‘Physics’, ‘Chemistry’, ‘Biology’];

  @override
  Void initState() {
Super.initState();
_tabController = TabController(length: 4, vsync: this);
_loadSettings();
  }

  Future<void> _loadSettings() async {
Try {
      DocumentReference settingsRef =
          Firestore.collection(‘settings’).doc(‘app’);
      DocumentSnapshot doc = await settingsRef.get();
      If (doc.exists) {
        Var data = doc.data() as Map<String, dynamic>?;
        If (data != null && data[‘subjects’] != null) {
          setState(() {
            subjects = List<String>.from(data[‘subjects’]);
          });
        }
      } else {
        Await settingsRef.set(
          {‘subjects’: subjects},
          SetOptions(merge: true),
        );
      }
} catch € {
      debugPrint(“Load settings error: $e”);
}
  }

  Future<void> _pickFile() async {
FilePickerResult? Result = await FilePicker.platform.pickFiles(
      Type: FileType.custom,
      allowedExtensions: [‘pdf’, ‘jpg’, ‘jpeg’, ‘png’, ‘docx’],
      withData: true,
);

If (result != null) {
      setState(() {
        _fileBytes = result.files.first.bytes;
        _fileName = result.files.first.name;
      });
}
  }

  Future<void> _uploadFile() async {
If (!_formKey.currentState!.validate() ||
        _fileBytes == null ||
        _fileName == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        Const SnackBar(
          Content: Text(‘Please pick a file first’),
        ),
      );
      Return;
}

String uniqueFileName = ‘${uuid.v4()}_$_fileName’;

setState(() => _isUploading = true);

try {
      // 1. Upload to Supabase
      Await supabase.storage
          .from(‘examhook-files’)
          .uploadBinary(uniqueFileName, _fileBytes!);

      String fileUrl = supabase.storage
          .from(‘examhook-files’)
          .getPublicUrl(uniqueFileName);

      // 2. Save to Firestore
      Await firestore.collection(‘resources’).add({
        ‘title’: _titleController.text,
        ‘course’: _course,
        ‘examType’: _examType,
        ‘fileUrl’: fileUrl,
        ‘fileName’: uniqueFileName,
        ‘fileSize’: _fileBytes!.length,
        ‘likes’: 0,
        ‘rating’: 0.0,
        ‘ratingCount’: 0,
        ‘downloads’: 0,
        ‘uploadedAt’: FieldValue.serverTimestamp()
      });

      ScaffoldMessenger.of(context).showSnackBar(
        Const SnackBar(
          Content: Text(‘Resource Uploaded!’),
          backgroundColor: Colors.green,
        ),
      );

      _titleController.clear();

      setState(() {
        _fileBytes = null;
        _fileName = null;
      });
} catch € {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          Content: Text(‘Error: $e’),
          backgroundColor: Colors.red,
        ),
      );
}

setState(() => _isUploading = false);
  }

  Future<void> _deleteResource(String docId, String fileName) async {
Bool confirm = await showDialog(
          Context: context,
          Builder: (context) => AlertDialog(
            Title: const Text(‘Delete Resource’),
            Content: const Text(
              ‘Delete this file from storage and database?’,
            ),
            Actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text(‘Cancel’),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                ),
                Child: const Text(‘Delete’),
              ),
            ],
          ),
        ) ??
        False;

If (confirm) {
      Try {
        Await supabase.storage
            .from(‘examhook-files’)
            .remove([fileName]);
      } catch € {
        debugPrint(“Supabase delete error: $e”);
      }

      Await firestore.collection(‘resources’).doc(docId).delete();

      ScaffoldMessenger.of(context).showSnackBar(
        Const SnackBar(
          Content: Text(‘Deleted’),
          backgroundColor: Colors.orange,
        ),
      );
}
  }

  Future<void> _approvePending(String docId, Map data) async {
Try {
      // Move file from pending_uploads/ to root
      String oldPath = data[‘fileName’];
      String newFileName =
          oldPath.replaceFirst(‘pending_uploads/’, ‘’);

      // Copy file in supabase
      Final bytes = await supabase.storage
          .from(‘examhook-files’)
          .download(oldPath);

      Await supabase.storage
          .from(‘examhook-files’)
          .uploadBinary(newFileName, bytes);

      String newUrl = supabase.storage
          .from(‘examhook-files’)
          .getPublicUrl(newFileName);

      // Delete old pending file
      Await supabase.storage
          .from(‘examhook-files’)
          .remove([oldPath]);

      // Add to resources collection
      Await firestore.collection(‘resources’).add({
        …data,
        ‘fileName’: newFileName,
        ‘fileUrl’: newUrl,
        ‘status’: ‘approved’,
        ‘uploadedAt’: FieldValue.serverTimestamp(),
      });

      Await firestore
          .collection(‘resources_pending’)
          .doc(docId)
          .delete();

      ScaffoldMessenger.of(context).showSnackBar(
        Const SnackBar(
          Content: Text(‘Approved!’),
          backgroundColor: Colors.green,
        ),
      );
} catch € {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          Content: Text(‘Approve failed: $e’),
          backgroundColor: Colors.red,
        ),
      );
}
  }

  Future<void> _rejectPending(
      String docId, String fileName) async {
Try {
      Await supabase.storage
          .from(‘examhook-files’)
          .remove([fileName]);
} catch € {
      debugPrint(“Supabase delete error: $e”);
}

Await firestore
        .collection(‘resources_pending’)
        .doc(docId)
        .delete();

    ScaffoldMessenger.of(context).showSnackBar(
      Const SnackBar(
        Content: Text(‘Rejected & Deleted’),
        backgroundColor: Colors.orange,
      ),
);
  }

  // NEW: View pending uploaded file before approving/rejecting.
  Future<void> _viewPendingFile(String fileUrl, String fileName) async {
If (fileUrl.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        Const SnackBar(
          Content: Text(‘File preview is not available.’),
          backgroundColor: Colors.red,
        ),
      );
      Return;
}

Final String lowerName = fileName.toLowerCase();
Final String lowerUrl = fileUrl.toLowerCase();

Final bool isImage = lowerName.endsWith(‘.jpg’) ||
        lowerName.endsWith(‘.jpeg’) ||
        lowerName.endsWith(‘.png’) ||
        lowerUrl.contains(‘.jpg’) ||
        lowerUrl.contains(‘.jpeg’) ||
        lowerUrl.contains(‘.png’);

if (isImage) {
      showDialog(
        context: context,
        builder: (context) {
          return Dialog(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppBar(
                  automaticallyImplyLeading: false,
                  title: Text(
                    fileName,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Actions: [
                    IconButton(
                      Icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                Flexible(
                  Child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: Image.network(
                      fileUrl,
                      fit: BoxFit.contain,
                      loadingBuilder:
                          (context, child, loadingProgress) {
                        If (loadingProgress == null) {
                          Return child;
                        }

                        Return const Padding(
                          Padding: EdgeInsets.all(40),
                          Child: Center(
                            Child: CircularProgressIndicator(),
                          ),
                        );
                      },
                      errorBuilder:
                          (context, error, stackTrace) {
                        Return const Padding(
                          Padding: EdgeInsets.all(30),
                          Child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.broken_image,
                                Size: 60,
                                Color: Colors.grey,
                              ),
                              SizedBox(height: 12),
                              Text(
                                ‘Unable to preview this image.’,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
} else {
      // PDFs and DOCX files are opened using the device/browser.
      Try {
        Final Uri uri = Uri.parse(fileUrl);

        Final bool launched = await launchUrl(
          Uri,
          Mode: LaunchMode.externalApplication,
        );

        If (!launched && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            Const SnackBar(
              Content: Text(‘Unable to open this file.’),
              backgroundColor: Colors.red,
            ),
          );
        }
      } catch € {
        If (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            Content: Text(‘Unable to open file: $e’),
            backgroundColor: Colors.red,
          ),
        );
      }
}
  }

  Future<void> _addSubject() async {
If (_newSubjectController.text.isEmpty) return;

String newSub = _newSubjectController.text.trim();

If (!subjects.contains(newSub)) {
      setState(() => subjects.add(newSub));

      await firestore
          .collection(‘settings’)
          .doc(‘app’)
          .set(
            {‘subjects’: subjects},
            SetOptions(merge: true),
          );

      _newSubjectController.clear();
}
  }

  Future<void> _deleteSubject(String subject) async {
setState(() => subjects.remove(subject));

await firestore
        .collection(‘settings’)
        .doc(‘app’)
        .set(
          {‘subjects’: subjects},
          SetOptions(merge: true),
        );
  }

  Future<void> _deleteRequest(String docId) async {
Await firestore
        .collection(‘requests’)
        .doc(docId)
        .delete();

    ScaffoldMessenger.of(context).showSnackBar(
      Const SnackBar(
        Content: Text(‘Request Deleted’),
        backgroundColor: Colors.orange,
      ),
);
  }

  Future<void> _deleteComment(
      String resourceId, String commentId) async {
Await firestore
        .collection(‘resources’)
        .doc(resourceId)
        .collection(‘comments’)
        .doc(commentId)
        .delete();
  }

  @override
  Widget build(BuildContext context) {
Const Color primaryGreen = Color(0xFF00C896);

Return Scaffold(
      appBar: AppBar(
        title: Text(
          ‘Admin Dashboard’,
          Style: GoogleFonts.poppins(
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: primaryGreen,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(
              Icon: Icon(Icons.upload),
              Text: ‘Upload’,
            ),
            Tab(
              Icon: Icon(Icons.list),
              Text: ‘Manage’,
            ),
            Tab(
              Icon: Icon(Icons.pending_actions),
              Text: ‘Pending’,
            ),
            Tab(
              Icon: Icon(Icons.settings),
              Text: ‘Settings’,
            ),
          ],
        ),
      ),
      Body: TabBarView(
        Controller: _tabController,
        Children: [
          // TAB 1: UPLOAD
          Padding(
            Padding: const EdgeInsets.all(16),
            Child: Form(
              Key: _formKey,
              Child: ListView(
                Children: [
                  TextFormField(
                    Controller: _titleController,
                    Decoration: const InputDecoration(
                      labelText: ‘Resource Title’,
                      border: OutlineInputBorder(),
                    ),
                    Validator: (val) =>
                        Val!.isEmpty ? ‘Enter title’ : null,
                  ),
                  Const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    Value: _course,
                    Decoration: const InputDecoration(
                      labelText: ‘Subject’,
                      border: OutlineInputBorder(),
                    ),
                    Items: subjects
                        .map(
                          € => DropdownMenuItem(
                            Value: e,
                            Child: Text€,
                          ),
                        )
                        .toList(),
                    onChanged: (val) =>
                        setState(() => _course = val!),
                  ),
                  Const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    Value: _examType,
                    Decoration: const InputDecoration(
                      labelText: ‘Exam Type’,
                      border: OutlineInputBorder(),
                    ),
                    Items: [
                      ‘ExamPrac’,
                      ‘Notes’,
                      ‘Quiz’,
                      ‘Assignment’
                    ]
                        .map(
                          € => DropdownMenuItem(
                            Value: e,
                            Child: Text€,
                          ),
                        )
                        .toList(),
                    onChanged: (val) =>
                        setState(() => _examType = val!),
                  ),
                  Const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _pickFile,
                    icon: const Icon(Icons.attach_file),
                    label: Text(
                      _fileName == null
                          ? ‘Pick File’
                          : _fileName!,
                    ),
                  ),
                  Const SizedBox(height: 24),
                  _isUploading
                      ? const Center(
                          Child: CircularProgressIndicator(),
                        )
                      : ElevatedButton.icon(
                          Icon: const Icon(Icons.cloud_upload),
                          Label: const Text(
                            ‘Upload to Supabase’,
                          ),
                          Style: ElevatedButton.styleFrom(
                            backgroundColor: primaryGreen,
                            minimumSize:
                                const Size(double.infinity, 50),
                          ),
                          onPressed: _uploadFile,
                        ),
                ],
              ),
            ),
          ),

          // TAB 2: MANAGE RESOURCES
          Column(
            Children: [
              Padding(
                Padding: const EdgeInsets.all(12),
                Child: TextField(
                  Controller: _searchController,
                  Decoration: InputDecoration(
                    hintText:
                        ‘Search resources by title, subject…’,
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onChanged: (val) => setState(
                    () => _searchQuery = val.toLowerCase(),
                  ),
                ),
              ),
              Expanded(
                Child: StreamBuilder<QuerySnapshot>(
                  Stream: firestore
                      .collection(‘resources’)
                      .orderBy(
                        ‘uploadedAt’,
                        Descending: true,
                      )
                      .snapshots(),
                  Builder: (context, snapshot) {
                    If (snapshot.connectionState ==
                        ConnectionState.waiting) {
                      Return const Center(
                        Child: CircularProgressIndicator(),
                      );
                    }

                    If (snapshot.hasError) {
                      Return Center(
                        Child: Text(
                          ‘Error: ${snapshot.error}’,
                        ),
                      );
                    }

                    If (!snapshot.hasData ||
                        Snapshot.data!.docs.isEmpty) {
                      Return Center(
                        Child: Text(
                          ‘No resources yet’,
                          Style: GoogleFonts.poppins(),
                        ),
                      );
                    }

                    Var docs = snapshot.data!.docs;

                    If (_searchQuery.isNotEmpty) {
                      Docs = docs.where((d) {
                        Var data =
                            d.data() as Map<String, dynamic>;

                        return data[‘title’]
                                .toString()
                                .toLowerCase()
                                .contains(_searchQuery) ||
                            Data[‘course’]
                                .toString()
                                .toLowerCase()
                                .contains(_searchQuery) ||
                            Data[‘examType’]
                                .toString()
                                .toLowerCase()
                                .contains(_searchQuery);
                      }).toList();
                    }

                    Return ListView.builder(
                      itemCount: docs.length,
                      itemBuilder: (context, index) {
                        var doc = docs[index];
                        var data =
                            doc.data() as Map<String, dynamic>;

                        return ExpansionTile(
                          leading: Icon(
                            _getFileIcon(
                              Data[‘fileUrl’] ?? ‘’,
                            ),
                            Color: primaryGreen,
                          ),
                          Title: Text(
                            Data[‘title’] ?? ‘’,
                            Style: GoogleFonts.poppins(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Subtitle: Text(
                            ‘${data[‘course’]} • ${data[‘examType’]}\n’
                            ‘Likes: ${data[‘likes’]} • ‘
                            ‘Rating: ${(data[‘rating’] ?? 0.0).toDouble().toStringAsFixed(1)} • ‘
                            ‘Downloads: ${data[‘downloads’]}’,
                          ),
                          Trailing: IconButton(
                            Icon: const Icon(
                              Icons.delete,
                              Color: Colors.red,
                            ),
                            onPressed: () => _deleteResource(
                              doc.id,
                              data[‘fileName’],
                            ),
                          ),
                          Children: [
                            StreamBuilder<QuerySnapshot>(
                              Stream: firestore
                                  .collection(‘resources’)
                                  .doc(doc.id)
                                  .collection(‘comments’)
                                  .orderBy(
                                    ‘timestamp’,
                                    Descending: true,
                                  )
                                  .snapshots(),
                              Builder: (context, snap) {
                                If (!snap.hasData ||
                                    Snap.data!.docs.isEmpty) {
                                  Return const Padding(
                                    Padding: EdgeInsets.all(8),
                                    Child: Text(‘No comments’),
                                  );
                                }

                                Return Column(
                                  Children: snap.data!.docs
                                      .map(© {
                                    Var cd =
                                        c.data() as Map;

                                    return ListTile(
                                      dense: true,
                                      title: Text(
                                        cd[‘text’] ?? ‘’,
                                        style:
                                            GoogleFonts.poppins(
                                          fontSize: 13,
                                        ),
                                      ),
                                      Subtitle: Text(
                                        Cd[‘user’] ??
                                            ‘Anonymous’,
                                        Style:
                                            GoogleFonts.poppins(
                                          fontSize: 11,
                                          color: Colors.grey,
                                        ),
                                      ),
                                      Trailing: IconButton(
                                        Icon: const Icon(
                                          Icons.delete_outline,
                                          Size: 18,
                                        ),
                                        onPressed: () =>
                                            _deleteComment(
                                          Doc.id,
                                          c.id,
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                );
                              },
                            )
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),

          // TAB 3: PENDING APPROVALS
          StreamBuilder<QuerySnapshot>(
            Stream: firestore
                .collection(‘resources_pending’)
                .orderBy(
                  ‘uploadedAt’,
                  Descending: true,
                )
                .snapshots(),
            Builder: (context, snap) {
              If (snap.connectionState ==
                  ConnectionState.waiting) {
                Return const Center(
                  Child: CircularProgressIndicator(),
                );
              }

              If (!snap.hasData ||
                  Snap.data!.docs.isEmpty) {
                Return Center(
                  Child: Text(
                    ‘No pending uploads’,
                    Style: GoogleFonts.poppins(),
                  ),
                );
              }

              Return ListView.builder(
                itemCount: snap.data!.docs.length,
                itemBuilder: (context, i) {
                  var doc = snap.data!.docs[i];
                  var data = doc.data() as Map;

                  final String fileUrl =
                      data[‘fileUrl’]?.toString() ?? ‘’;

                  final String fileName =
                      data[‘fileName’]?.toString() ??
                          data[‘title’]?.toString() ??
                          ‘Uploaded File’;

                  Return Card(
                    Margin: const EdgeInsets.all(8),
                    Child: ListTile(
                      Leading: Icon(
                        _getFileIcon(
                          Data[‘fileUrl’] ?? ‘’,
                        ),
                        Color: Colors.orange,
                      ),
                      Title: Text(
                        Data[‘title’] ?? ‘’,
                      ),
                      Subtitle: Text(
                        ‘${data[‘course’]} • ${data[‘examType’]}\n’
                        ‘Submitted: ${data[‘uploadedAt’] != null ? DateFormat(‘dd MMM’).format((data[‘uploadedAt’] as Timestamp).toDate()) : ‘’}’,
                      ),
                      Trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // NEW: View file before decision
                          IconButton(
                            Tooltip: ‘View File’,
                            Icon: const Icon(
                              Icons.visibility,
                              Color: Colors.blue,
                            ),
                            onPressed: fileUrl.isEmpty
                                ? null
                                : () => _viewPendingFile(
                                      fileUrl,
                                      fileName,
                                    ),
                          ),
                          IconButton(
                            Tooltip: ‘Approve’,
                            Icon: const Icon(
                              Icons.check_circle,
                              Color: Colors.green,
                            ),
                            onPressed: () =>
                                _approvePending(
                              Doc.id,
                              Data,
                            ),
                          ),
                          IconButton(
                            Tooltip: ‘Reject’,
                            Icon: const Icon(
                              Icons.cancel,
                              Color: Colors.red,
                            ),
                            onPressed: () =>
                                _rejectPending(
                              Doc.id,
                              Data[‘fileName’],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),

          // TAB 4: SETTINGS + REQUESTS
          Padding(
            Padding: const EdgeInsets.all(16),
            Child: ListView(
              Children: [
                Text(
                  ‘Manage Subjects’,
                  Style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Row(
                  Children: [
                    Expanded(
                      Child: TextField(
                        Controller: _newSubjectController,
                        Decoration: const InputDecoration(
                          labelText: ‘New Subject’,
                        ),
                      ),
                    ),
                    IconButton(
                      Icon: const Icon(
                        Icons.add_circle,
                        Color: Color(0xFF00C896),
                        Size: 32,
                      ),
                      onPressed: _addSubject,
                    ),
                  ],
                ),
                Const SizedBox(height: 10),
                Wrap(
                  Spacing: 8,
                  Children: subjects
                      .map(
                        (s) => Chip(
                          Label: Text(s),
                          deleteIcon:
                              const Icon(Icons.close, size: 18),
                          onDeleted: () =>
                              _deleteSubject(s),
                        ),
                      )
                      .toList(),
                ),
                Const Divider(height: 40),
                Text(
                  ‘User Requests’,
                  Style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Const SizedBox(height: 10),
                StreamBuilder<QuerySnapshot>(
                  Stream: firestore
                      .collection(‘requests’)
                      .orderBy(
                        ‘timestamp’,
                        Descending: true,
                      )
                      .snapshots(),
                  Builder: (context, snap) {
                    If (snap.connectionState ==
                        ConnectionState.waiting) {
                      Return const Center(
                        Child: CircularProgressIndicator(),
                      );
                    }

                    If (snap.hasError) {
                      Return Text(
                        ‘Error: ${snap.error}’,
                      );
                    }

                    If (!snap.hasData ||
                        Snap.data!.docs.isEmpty) {
                      Return Center(
                        Child: Padding(
                          Padding: const EdgeInsets.all(20),
                          Child: Text(
                            ‘No requests yet’,
                            Style: GoogleFonts.poppins(
                              Color: Colors.grey,
                            ),
                          ),
                        ),
                      );
                    }

                    Return Column(
                      Children: snap.data!.docs.map((d) {
                        Var data =
                            d.data() as Map<String, dynamic>;

                        return Card(
                          child: ListTile(
                            leading: const Icon(
                              Icons.mail,
                              Color: Colors.orange,
                            ),
                            Title: Text(
                              Data[‘subject’] ??
                                  ‘No Subject’,
                              Style: GoogleFonts.poppins(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Subtitle: Text(
                              ‘${data[‘message’] ?? ‘’}\n’
                              ‘${data[‘timestamp’] != null ? DateFormat(‘dd MMM, hh:mm a’).format((data[‘timestamp’] as Timestamp).toDate()) : ‘’}’,
                              Style: GoogleFonts.poppins(
                                fontSize: 12,
                              ),
                            ),
                            Trailing: IconButton(
                              Icon: const Icon(
                                Icons.delete,
                                Color: Colors.red,
                              ),
                              onPressed: () =>
                                  _deleteRequest(d.id),
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                )
              ],
            ),
          ),
        ],
      ),
);
  }

  IconData _getFileIcon(String url) {
If (url.contains(‘.pdf’)) {
      Return Icons.picture_as_pdf;
}

If (url.contains(‘.jpg’) ||
        url.contains(‘.png’) ||
        url.contains(‘.jpeg’)) {
      return Icons.image;
}

If (url.contains(‘.docx’)) {
      Return Icons.description;
}

Return Icons.insert_drive_file;
  }
}

