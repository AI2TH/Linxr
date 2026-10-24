import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/marketplace_item.dart';
import '../services/marketplace_service.dart';
import '../services/vm_platform.dart';
import '../theme.dart';

class MarketplaceScreen extends StatefulWidget {
  const MarketplaceScreen({super.key});

  @override
  State<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends State<MarketplaceScreen> {
  List<MarketplaceItem> _items = [];
  Map<String, Map<String, dynamic>> _runningContainersByImage = {};
  final Set<String> _inProgressItemIds = {};
  bool _isLoading = false;
  String _selectedCategory = 'All';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounceTimer;

  final List<String> _categories = [
    'All',
    'Kubernetes & DevOps',
    'Dev Environments',
    'AI & ML',
    'Web & Cloud',
    'Databases',
    'Networking & Tools',
    'Dev Tools',
    'My Custom',
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        setState(() {
          _searchQuery = _searchController.text.trim();
        });
      }
    });
  }

  Future<void> _loadData({bool refreshRemote = false}) async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final items = await MarketplaceService.getAllItems(refreshRemote: refreshRemote);
      final containers = await VmPlatform.listContainers();

      final Map<String, Map<String, dynamic>> runningByImage = {};
      for (final c in containers) {
        final status = (c['status'] as String? ?? '').toLowerCase();
        if (status.contains('up')) {
          final image = (c['image'] as String? ?? '').toLowerCase();
          runningByImage[image] = c;
          // Also match without registry/tag (e.g. nginx for nginx:alpine)
          final baseName = image.split(':').first.split('/').last;
          runningByImage[baseName] = c;
        }
      }

      if (!mounted) return;
      setState(() {
        _items = items;
        _runningContainersByImage = runningByImage;
      });
    } catch (e) {
      debugPrint('Error loading marketplace data: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  int _getCountForCategory(String cat) {
    if (cat == 'All') return _items.length;
    if (cat == 'My Custom') return _items.where((i) => i.isCustom).length;
    return _items.where((i) => i.category == cat).length;
  }

  List<MarketplaceItem> get _filteredItems {
    return _items.where((item) {
      if (_selectedCategory == 'My Custom') {
        if (!item.isCustom) return false;
      } else if (_selectedCategory != 'All') {
        if (item.category != _selectedCategory) return false;
      }

      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchName = item.name.toLowerCase().contains(q);
        final matchDesc = item.description.toLowerCase().contains(q);
        final matchCategory = item.category.toLowerCase().contains(q);
        final matchImage = (item.image ?? '').toLowerCase().contains(q);
        final matchAuthor = item.author.toLowerCase().contains(q);
        return matchName || matchDesc || matchCategory || matchImage || matchAuthor;
      }

      return true;
    }).toList();
  }

  Map<String, dynamic>? _getRunningContainer(MarketplaceItem item) {
    if (item.image == null) return null;
    final img = item.image!.toLowerCase();
    if (_runningContainersByImage.containsKey(img)) {
      return _runningContainersByImage[img];
    }
    final base = img.split(':').first.split('/').last;
    return _runningContainersByImage[base];
  }

  Future<void> _openWebUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not launch $url. Try opening it manually in Chrome.'),
              backgroundColor: AppColors.warning,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to open URL: $e'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final vmState = context.watch<VmState>();
    final isVmRunning = vmState.isRunning;
    final isVmHealthy = vmState.isHealthy;
    final filtered = _filteredItems;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'Marketplace & Recipes',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 19),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'Add / Import Recipe',
            onPressed: () => _showAddRecipeDialog(),
          ),
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Sync Community Recipes (AI2TH/linxr-marketplace)',
            onPressed: () async {
              await _loadData(refreshRemote: true);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Marketplace synced with AI2TH/linxr-marketplace!'),
                    backgroundColor: AppColors.secondary,
                    behavior: SnackBarBehavior.floating,
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
        children: [
          // VM Status Warning Banner if VM is stopped or initializing
          if (!isVmRunning)
            _buildVmWarningBanner(
              icon: Icons.power_settings_new,
              color: AppColors.warning,
              message: 'VM is currently stopped. Start VM to deploy containers or run scripts.',
              buttonText: 'Start VM',
              onAction: () => context.read<VmState>().startVm(),
            )
          else if (!isVmHealthy)
            _buildVmWarningBanner(
              icon: Icons.hourglass_top,
              color: AppColors.brightBlue,
              message: 'Docker & REST engine are initializing... (ready in ~30s)',
              buttonText: 'Check Status',
              onAction: () => context.read<VmState>().refreshStatus(),
            ),

          // Search & Filter header
          _buildSearchAndFilterHeader(),

          // Main list with compensated scrolling
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  )
                : filtered.isEmpty
                    ? _buildEmptyState()
                    : RefreshIndicator(
                        onRefresh: () => _loadData(refreshRemote: true),
                        color: AppColors.primary,
                        backgroundColor: AppColors.surface,
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final item = filtered[index];
                            final runningInfo = _getRunningContainer(item);
                            final isRunning = runningInfo != null;
                            final isDeploying = _inProgressItemIds.contains(item.id);

                            return _buildRecipeCard(
                              item: item,
                              isRunning: isRunning,
                              runningInfo: runningInfo,
                              isDeploying: isDeploying,
                              isVmRunning: isVmRunning,
                              isVmHealthy: isVmHealthy,
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildVmWarningBanner({
    required IconData icon,
    required Color color,
    required String message,
    required String buttonText,
    required VoidCallback onAction,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        border: Border(bottom: BorderSide(color: color.withOpacity(0.3))),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: color,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              buttonText,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilterHeader() {
    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: Column(
        children: [
          // Search Bar with instant debounce
          TextField(
            controller: _searchController,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search templates, k8s, AI, databases, web...',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 13),
              prefixIcon: Icon(Icons.search, color: Colors.white.withOpacity(0.4), size: 20),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      color: Colors.white60,
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              filled: true,
              fillColor: AppColors.surface,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Horizontal Category Chips with Item Count
          SizedBox(
            height: 36,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _categories.length,
              itemBuilder: (context, idx) {
                final category = _categories[idx];
                final isSelected = _selectedCategory == category;
                final count = _getCountForCategory(category);

                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: FilterChip(
                    label: Text(
                      '$category ($count)',
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white60,
                        fontSize: 11,
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal,
                      ),
                    ),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() => _selectedCategory = category);
                      }
                    },
                    backgroundColor: AppColors.surface,
                    selectedColor: AppColors.primary.withOpacity(0.3),
                    checkmarkColor: AppColors.brightBlue,
                    side: BorderSide(
                      color: isSelected ? AppColors.primary : Colors.white.withOpacity(0.08),
                    ),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),

          // Community Catalog Status Bar
          Row(
            children: [
              const Icon(Icons.hub_outlined, size: 13, color: AppColors.brightBlue),
              const SizedBox(width: 5),
              const Text(
                'AI2TH/linxr-marketplace',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.brightBlue,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                'Pull to sync community updates',
                style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.35)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.storefront_outlined, size: 64, color: Colors.white.withOpacity(0.2)),
            const SizedBox(height: 16),
            const Text(
              'No matching recipes found',
              style: TextStyle(fontSize: 17, color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No results for "$_searchQuery". Try searching another term.'
                  : 'No recipes available in "$_selectedCategory".',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () => _showAddRecipeDialog(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Create Custom Recipe'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecipeCard({
    required MarketplaceItem item,
    required bool isRunning,
    required Map<String, dynamic>? runningInfo,
    required bool isDeploying,
    required bool isVmRunning,
    required bool isVmHealthy,
  }) {
    final isDocker = item.isDocker;
    final webUrl = item.webUrl;
    final hasWeb = item.hasWebUi;

    return Card(
      color: AppColors.surface,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isRunning
              ? AppColors.secondary.withOpacity(0.5)
              : isDeploying
                  ? AppColors.primary.withOpacity(0.5)
                  : Colors.white.withOpacity(0.08),
          width: isRunning ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _showItemDetailsSheet(item, isRunning, runningInfo, isVmRunning, isVmHealthy),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top Row: Icon + Title + Status badges
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: isDocker
                          ? AppColors.primary.withOpacity(0.15)
                          : AppColors.termMagenta.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isDocker
                            ? AppColors.primary.withOpacity(0.35)
                            : AppColors.termMagenta.withOpacity(0.35),
                      ),
                    ),
                    child: Icon(
                      item.iconData,
                      color: isDocker ? AppColors.brightBlue : AppColors.brightMagenta,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                item.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isRunning) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.secondary.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: AppColors.secondary.withOpacity(0.5)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: const [
                                    Icon(Icons.circle, size: 6, color: AppColors.secondary),
                                    SizedBox(width: 4),
                                    Text(
                                      'RUNNING',
                                      style: TextStyle(
                                        color: AppColors.secondary,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ] else if (isDeploying) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.brightBlue.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: AppColors.brightBlue.withOpacity(0.5)),
                                ),
                                child: const Text(
                                  'DEPLOYING...',
                                  style: TextStyle(
                                    color: AppColors.brightBlue,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${item.author} • ${item.version}',
                          style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 11),
                        ),
                      ],
                    ),
                  ),

                  // Type Tag
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isDocker
                          ? AppColors.primary.withOpacity(0.12)
                          : AppColors.termMagenta.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isDocker
                            ? AppColors.primary.withOpacity(0.4)
                            : AppColors.termMagenta.withOpacity(0.4),
                      ),
                    ),
                    child: Text(
                      isDocker ? 'DOCKER' : 'SCRIPT',
                      style: TextStyle(
                        color: isDocker ? AppColors.brightBlue : AppColors.brightMagenta,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Description
              Text(
                item.description,
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.3),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),

              // Bottom Info Bar: Port, Category, and Action Buttons
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          item.category,
                          style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 11),
                        ),
                      ),
                      if (item.ports.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.brightGreen.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Port ${item.ports.first['host'] ?? ''}',
                            style: const TextStyle(color: AppColors.brightGreen, fontSize: 11),
                          ),
                        ),
                    ],
                  ),

                  // Quick Action Buttons
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (isRunning && hasWeb && webUrl != null)
                        OutlinedButton.icon(
                          onPressed: () => _openWebUrl(webUrl),
                          icon: const Icon(Icons.open_in_browser, size: 14),
                          label: const Text('Open UI'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.secondary,
                            side: BorderSide(color: AppColors.secondary.withOpacity(0.5)),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),

                      ElevatedButton(
                        onPressed: isDeploying
                            ? () => _startDeploymentWithProgressModal(item)
                            : () => _showItemDetailsSheet(
                                  item,
                                  isRunning,
                                  runningInfo,
                                  isVmRunning,
                                  isVmHealthy,
                                ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isRunning
                              ? Colors.white.withOpacity(0.1)
                              : isDocker
                                  ? AppColors.primary
                                  : AppColors.termMagenta,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.white.withOpacity(0.1),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          elevation: 0,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isDeploying) ...[
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              ),
                              const SizedBox(width: 6),
                              const Text('Working...', style: TextStyle(fontSize: 12)),
                            ] else ...[
                              Icon(
                                isRunning
                                    ? Icons.settings
                                    : isDocker
                                        ? Icons.play_arrow
                                        : Icons.terminal,
                                size: 14,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isRunning
                                    ? 'Manage'
                                    : isDocker
                                        ? 'Deploy'
                                        : 'Run Script',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ],
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
  }

  // ---------------------------------------------------------------------------
  // Interactive Live Deployment & Details Bottom Sheet
  // ---------------------------------------------------------------------------

  void _showItemDetailsSheet(
    MarketplaceItem item,
    bool isRunning,
    Map<String, dynamic>? runningInfo,
    bool isVmRunning,
    bool isVmHealthy,
  ) {
    final isDocker = item.isDocker;
    final defaultContainerName = runningInfo != null
        ? (runningInfo['name'] as String? ?? item.id)
        : '${item.id}_${DateTime.now().millisecondsSinceEpoch % 10000}';
    final nameController = TextEditingController(text: defaultContainerName);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (context, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.85,
              ),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Handle bar
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Title Header
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: isDocker
                                ? AppColors.primary.withOpacity(0.15)
                                : AppColors.termMagenta.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isDocker
                                  ? AppColors.primary.withOpacity(0.4)
                                  : AppColors.termMagenta.withOpacity(0.4),
                            ),
                          ),
                          child: Icon(
                            item.iconData,
                            color: isDocker ? AppColors.brightBlue : AppColors.brightMagenta,
                            size: 26,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${item.author} • ${item.version}',
                                style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        if (item.isCustom)
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                            tooltip: 'Delete custom recipe',
                            onPressed: () async {
                              await MarketplaceService.deleteCustomItem(item.id);
                              Navigator.pop(sheetCtx);
                              _loadData();
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Description & Notes
                    Text(
                      item.description,
                      style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
                    ),
                    const SizedBox(height: 14),

                    if (item.notes != null && item.notes!.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.brightBlue.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.brightBlue.withOpacity(0.25)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.info_outline, color: AppColors.brightBlue, size: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                item.notes!,
                                style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.3),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],

                    // Running Actions (If already active)
                    if (isRunning && runningInfo != null) ...[
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.secondary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.secondary.withOpacity(0.35)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.check_circle, color: AppColors.secondary, size: 18),
                                const SizedBox(width: 8),
                                Text(
                                  'Container is Active: ${runningInfo['name']}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                if (item.webUrl != null) ...[
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () => _openWebUrl(item.webUrl!),
                                      icon: const Icon(Icons.open_in_browser, size: 16),
                                      label: const Text('Open Web UI'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.secondary,
                                        foregroundColor: Colors.black,
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () => _showContainerLogs(runningInfo['name'] as String),
                                    icon: const Icon(Icons.text_snippet_outlined, size: 16),
                                    label: const Text('Logs'),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white,
                                      side: BorderSide(color: Colors.white.withOpacity(0.2)),
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  icon: const Icon(Icons.stop_circle_outlined, color: AppColors.danger),
                                  tooltip: 'Stop Container',
                                  onPressed: () async {
                                    final name = runningInfo['name'] as String;
                                    await MarketplaceService.stopContainer(name);
                                    Navigator.pop(sheetCtx);
                                    _loadData();
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Docker Configuration Details (if deploying new instance)
                    if (isDocker) ...[
                      const Text(
                        'Container Configuration',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: nameController,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'Container Name',
                          labelStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                          prefixIcon: const Icon(Icons.tag, size: 18, color: Colors.white54),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.04),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (item.ports.isNotEmpty) ...[
                        Row(
                          children: [
                            const Icon(Icons.router_outlined, size: 16, color: AppColors.brightGreen),
                            const SizedBox(width: 6),
                            Text(
                              'Forwarded Port: ${item.ports.first['host']} -> Container ${item.ports.first['container']}',
                              style: const TextStyle(color: AppColors.brightGreen, fontSize: 12),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                      ],
                    ] else ...[
                      // Shell Script Preview
                      const Text(
                        'Automation Script Preview',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white.withOpacity(0.1)),
                        ),
                        child: Text(
                          item.script ?? '',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            color: AppColors.termGreen,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),

                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(sheetCtx),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white60,
                              side: BorderSide(color: Colors.white.withOpacity(0.15)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text('Close'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: !isVmRunning
                                ? () {
                                    Navigator.pop(sheetCtx);
                                    context.read<VmState>().startVm();
                                  }
                                : () {
                                    Navigator.pop(sheetCtx);
                                    _startDeploymentWithProgressModal(
                                      item,
                                      customName: nameController.text.trim(),
                                    );
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: !isVmRunning
                                  ? AppColors.warning
                                  : isDocker
                                      ? AppColors.primary
                                      : AppColors.termMagenta,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: Text(
                              !isVmRunning
                                  ? 'Start VM to Run'
                                  : isDocker
                                      ? (isRunning ? 'Deploy New Instance' : 'Deploy Container')
                                      : 'Execute Script',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Dedicated Live Deployment Progress Modal (Eliminates Unknown Errors)
  // ---------------------------------------------------------------------------

  void _startDeploymentWithProgressModal(
    MarketplaceItem item, {
    String? customName,
  }) {
    setState(() => _inProgressItemIds.add(item.id));

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dlgCtx) => _LiveDeploymentDialog(
        item: item,
        customName: customName,
        onDone: () {},
      ),
    ).then((_) {
      if (mounted) {
        setState(() => _inProgressItemIds.remove(item.id));
        _loadData();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Container Logs Modal
  // ---------------------------------------------------------------------------

  void _showContainerLogs(String containerName) async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Row(
          children: [
            const Icon(Icons.text_snippet_outlined, color: AppColors.brightBlue, size: 20),
            const SizedBox(width: 8),
            Text(
              'Logs: $containerName',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: FutureBuilder<String>(
            future: MarketplaceService.getContainerLogs(containerName),
            builder: (ctx, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final logs = snapshot.data ?? 'No logs available.';
              return Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    logs.isEmpty ? 'No logs output yet.' : logs,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: AppColors.termGreen,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Add / Import Recipe Dialog
  // ---------------------------------------------------------------------------

  void _showAddRecipeDialog() {
    int activeTab = 0; // 0 = Manual, 1 = Import JSON
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final categoryController = TextEditingController(text: 'Kubernetes & DevOps');
    final targetController = TextEditingController();
    final portsController = TextEditingController();
    final jsonController = TextEditingController();
    RecipeType recipeType = RecipeType.docker;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Create / Import Recipe',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Tabs
                  Row(
                    children: [
                      Expanded(
                        child: ChoiceChip(
                          label: const Center(child: Text('Manual Form')),
                          selected: activeTab == 0,
                          onSelected: (val) => setModalState(() => activeTab = 0),
                          selectedColor: AppColors.primary.withOpacity(0.25),
                          backgroundColor: Colors.white.withOpacity(0.05),
                          labelStyle: TextStyle(
                            color: activeTab == 0 ? Colors.white : Colors.white60,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ChoiceChip(
                          label: const Center(child: Text('Import JSON')),
                          selected: activeTab == 1,
                          onSelected: (val) => setModalState(() => activeTab = 1),
                          selectedColor: AppColors.primary.withOpacity(0.25),
                          backgroundColor: Colors.white.withOpacity(0.05),
                          labelStyle: TextStyle(
                            color: activeTab == 1 ? Colors.white : Colors.white60,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  if (activeTab == 0) ...[
                    Row(
                      children: [
                        const Text('Type: ', style: TextStyle(color: Colors.white70)),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('Docker'),
                          selected: recipeType == RecipeType.docker,
                          onSelected: (v) => setModalState(() => recipeType = RecipeType.docker),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('Shell Script'),
                          selected: recipeType == RecipeType.script,
                          onSelected: (v) => setModalState(() => recipeType = RecipeType.script),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildField(nameController, 'Recipe Name', 'e.g. Grafana, PostgreSQL 17'),
                    const SizedBox(height: 10),
                    _buildField(categoryController, 'Category', 'e.g. Kubernetes & DevOps, AI & ML'),
                    const SizedBox(height: 10),
                    _buildField(
                      targetController,
                      recipeType == RecipeType.docker ? 'Docker Image' : 'Shell Command',
                      recipeType == RecipeType.docker ? 'e.g. grafana/grafana:latest' : 'e.g. apk add htop',
                    ),
                    if (recipeType == RecipeType.docker) ...[
                      const SizedBox(height: 10),
                      _buildField(portsController, 'Port Mapping', 'e.g. 3000:3000'),
                    ],
                    const SizedBox(height: 10),
                    _buildField(descController, 'Description', 'What does this recipe do?'),
                  ] else ...[
                    const Text(
                      'Paste Recipe JSON:',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: jsonController,
                      maxLines: 7,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: AppColors.termGreen),
                      decoration: InputDecoration(
                        hintText: '{\n  "name": "Custom Stack",\n  "type": "docker", ...\n}',
                        hintStyle: TextStyle(color: Colors.white.withOpacity(0.25)),
                        filled: true,
                        fillColor: AppColors.background,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],

                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(sheetCtx),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: () async {
                            try {
                              if (activeTab == 0) {
                                if (nameController.text.trim().isEmpty) return;
                                List<Map<String, dynamic>> ports = [];
                                if (portsController.text.trim().isNotEmpty) {
                                  final pParts = portsController.text.trim().split(':');
                                  if (pParts.length == 2) {
                                    ports = [
                                      {'host': int.tryParse(pParts[0]) ?? 8080, 'container': int.tryParse(pParts[1]) ?? 80}
                                    ];
                                  }
                                }

                                final item = MarketplaceItem(
                                  id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
                                  name: nameController.text.trim(),
                                  category: categoryController.text.trim().isEmpty
                                      ? 'Community'
                                      : categoryController.text.trim(),
                                  type: recipeType,
                                  description: descController.text.trim(),
                                  image: recipeType == RecipeType.docker ? targetController.text.trim() : null,
                                  script: recipeType == RecipeType.script ? targetController.text.trim() : null,
                                  ports: ports,
                                  isCustom: true,
                                );
                                await MarketplaceService.saveCustomItem(item);
                              } else {
                                final item = MarketplaceService.importRecipeFromJson(jsonController.text.trim());
                                await MarketplaceService.saveCustomItem(item);
                              }
                              Navigator.pop(sheetCtx);
                              _loadData();
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Error saving recipe: $e')),
                              );
                            }
                          },
                          style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
                          child: const Text('Save Recipe', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildField(TextEditingController ctrl, String label, String hint) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
        hintText: hint,
        hintStyle: TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 12),
        filled: true,
        fillColor: Colors.white.withOpacity(0.04),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Live Deployment Progress Dialog (Step-by-Step with Real Feedback)
// -----------------------------------------------------------------------------

class _LiveDeploymentDialog extends StatefulWidget {
  final MarketplaceItem item;
  final String? customName;
  final VoidCallback onDone;

  const _LiveDeploymentDialog({
    required this.item,
    this.customName,
    required this.onDone,
  });

  @override
  State<_LiveDeploymentDialog> createState() => _LiveDeploymentDialogState();
}

class _LiveDeploymentDialogState extends State<_LiveDeploymentDialog> {
  int _currentStep = 0; // 0=Preparing, 1=Pulling/Running, 2=Done, -1=Error
  String _stepMessage = 'Verifying VM state and Docker engine...';
  String _errorMessage = '';
  String _detailedOutput = '';

  @override
  void initState() {
    super.initState();
    _executeDeployment();
  }

  Future<void> _executeDeployment() async {
    setState(() {
      _currentStep = 0;
      _stepMessage = 'Connecting to VM API server...';
      _errorMessage = '';
      _detailedOutput = '';
    });

    try {
      // Step 0: Ensure VM is alive
      final status = await VmPlatform.getVmStatus();
      if (status != 'running') {
        throw Exception('Alpine Linux VM is not running.\nPlease start the VM from the Home tab first.');
      }

      // Check if VM daemon/API is healthy, polling up to 15 seconds if it's still booting
      setState(() {
        _stepMessage = 'Checking Docker daemon & VM runtime readiness...';
      });

      bool ready = await VmPlatform.checkHealth();
      int waitSeconds = 0;
      while (!ready && waitSeconds < 15) {
        await Future.delayed(const Duration(seconds: 1));
        waitSeconds++;
        if (!mounted) return;
        setState(() {
          _stepMessage = 'VM services starting up (${waitSeconds}s/15s)...';
        });
        ready = await VmPlatform.checkHealth();
      }

      if (!ready && widget.item.isDocker) {
        throw Exception(
          'Docker engine is still initializing inside Alpine Linux.\nPlease wait ~10 seconds and tap Retry.',
        );
      }

      // Step 1: Execute deployment
      final bool isHeavyImage = (widget.item.image?.contains('ollama/ollama') ?? false) ||
          (widget.item.image?.contains('code-server') ?? false);
      setState(() {
        _currentStep = 1;
        _stepMessage = widget.item.isDocker
            ? (isHeavyImage
                ? 'Pulling "${widget.item.image}" (approx. 2.7 GB)...\nThis can take 15–30+ minutes in emulated QEMU.\nTap "Background" to let it run while using the app.'
                : 'Pulling "${widget.item.image}" & initializing container...\n(May take 30-90s on first download)')
            : 'Executing recipe script inside VM...';
      });

      if (widget.item.isDocker) {
        await MarketplaceService.deployDocker(
          widget.item,
          customName: widget.customName,
        );
        setState(() {
          _currentStep = 2;
          _stepMessage = 'Container deployed successfully!';
        });
      } else {
        final res = await MarketplaceService.executeScript(widget.item.script ?? '');
        final stdout = res['stdout'] as String? ?? '';
        final stderr = res['stderr'] as String? ?? '';
        final exitCode = (res['exitCode'] as num?)?.toInt() ?? 0;

        String out = stdout;
        if (stderr.isNotEmpty) {
          out += (out.isNotEmpty ? '\n' : '') + stderr;
        }

        if (exitCode != 0) {
          throw Exception('Script failed with exit code $exitCode:\n$out');
        }

        setState(() {
          _currentStep = 2;
          _stepMessage = 'Script executed successfully!';
          _detailedOutput = out;
        });
      }
    } catch (e) {
      if (widget.item.isDocker) {
        try {
          final containers = await VmPlatform.listContainers();
          final running = containers.any((c) {
            final name = (c['name'] as String? ?? '').toLowerCase();
            final image = (c['image'] as String? ?? '').toLowerCase();
            final targetName = (widget.customName ?? widget.item.id).toLowerCase();
            final targetImage = (widget.item.image ?? widget.item.id).toLowerCase();
            final isUp = (c['status'] as String? ?? '').toLowerCase().contains('up');
            return isUp && (name.contains(targetName) || image.contains(targetImage));
          });
          if (running) {
            if (mounted) {
              setState(() {
                _currentStep = 2;
                _stepMessage = 'Container deployed and running successfully!';
              });
            }
            return;
          }
        } catch (_) {}
      }

      String msg = '';
      if (e is PlatformException) {
        msg = e.message ?? e.toString();
        if (e.details != null && e.details.toString().isNotEmpty) {
          msg += '\n${e.details}';
        }
      } else {
        msg = e.toString().replaceFirst('Exception: ', '').trim();
      }

      // Check if message contains JSON with "detail" field (e.g. FastAPI HTTPException)
      if (msg.contains('"detail"')) {
        try {
          final jsonStart = msg.indexOf('{');
          final jsonEnd = msg.lastIndexOf('}');
          if (jsonStart != -1 && jsonEnd != -1 && jsonEnd > jsonStart) {
            final jsonStr = msg.substring(jsonStart, jsonEnd + 1);
            final decoded = jsonDecode(jsonStr);
            if (decoded is Map && decoded.containsKey('detail')) {
              msg = decoded['detail'].toString();
            }
          }
        } catch (_) {}
      }

      if (msg.contains('Failed to connect to /127.0.0.1:7081') ||
          msg.contains('Connection refused')) {
        msg =
            'Unable to connect to Linxr VM daemon on port 7081. The Alpine VM service is still booting. Please wait a few seconds and tap Retry.';
      } else if (msg.toLowerCase().contains('timeout') ||
          msg.contains('timed out') ||
          msg.contains('TimeoutExpired')) {
        if (widget.item.id == 'ollama' || (widget.item.image?.contains('ollama') ?? false)) {
          msg =
              'Operation timed out: The Ollama image is ~2.7 GB compressed (~5.5 GB uncompressed) and can require 30+ minutes to download and extract in emulated Linux.\n\nTip: You can monitor progress or pull it directly in the Terminal tab by running:\ndocker pull ollama/ollama:latest';
        } else {
          msg =
              'Operation timed out. Pulling large container images may take several minutes depending on network speed. Check progress in Terminal with "docker ps".';
        }
      }

      if (mounted) {
        setState(() {
          _currentStep = -1;
          _errorMessage = msg;
        });
      }
    }
  }

  Future<void> _openWebUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDone = _currentStep == 2;
    final isError = _currentStep == -1;
    final webUrl = widget.item.webUrl;

    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(
            isDone
                ? Icons.check_circle
                : isError
                    ? Icons.error_outline
                    : Icons.cloud_download_outlined,
            color: isDone
                ? AppColors.secondary
                : isError
                    ? AppColors.danger
                    : AppColors.primary,
            size: 24,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isDone
                  ? 'Ready: ${widget.item.name}'
                  : isError
                      ? 'Deployment Failed'
                      : 'Deploying ${widget.item.name}',
              style: const TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isDone && !isError) ...[
              const LinearProgressIndicator(color: AppColors.primary),
              const SizedBox(height: 16),
            ],
            Text(
              _stepMessage,
              style: TextStyle(
                color: isError ? AppColors.danger : Colors.white70,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            if (isError) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.danger.withOpacity(0.3)),
                ),
                child: Text(
                  _errorMessage,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: AppColors.termRed,
                  ),
                ),
              ),
            ],
            if (isDone && _detailedOutput.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                height: 120,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _detailedOutput,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: AppColors.termGreen),
                  ),
                ),
              ),
            ],
            if (isDone && webUrl != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.secondary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.secondary.withOpacity(0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.language, color: AppColors.secondary, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Web Interface Live',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                          Text(
                            webUrl,
                            style: const TextStyle(color: AppColors.brightGreen, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () => _openWebUrl(webUrl),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.secondary,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Open UI', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (isError) ...[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Dismiss', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            onPressed: () => _executeDeployment(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('Retry', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ] else if (isDone) ...[
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.secondary, foregroundColor: Colors.black),
            child: const Text('Done', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ] else ...[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Background', style: TextStyle(color: Colors.white60)),
          ),
        ],
      ],
    );
  }
}
