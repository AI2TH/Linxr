import 'package:flutter/material.dart';

/// Centralized theme colors — single source of truth for all Color(0xFF...) literals.
///
/// Rebrand or theme tweaks require editing only this file.
class AppColors {
  AppColors._();

  // ── Brand palette ───────────────────────────────────────────────────────────

  static const Color primary    = Color(0xFF0D6EFD);  // Blue — buttons, links, active nav
  static const Color secondary  = Color(0xFF20C997);  // Green — running status, success
  static const Color warning    = Color(0xFFFFC107);  // Amber — booting, connecting, warnings
  static const Color danger     = Color(0xFFDC3545);  // Red — errors, stop button
  static const Color surface    = Color(0xFF1A1D23);  // Card/panel background
  static const Color background = Color(0xFF0E1117);  // Scaffold background
  static const Color navRail    = Color(0xFF111827);  // Navigation rail / bottom nav bg

  // ── Terminal palette ────────────────────────────────────────────────────────

  static const Color termGreen   = Color(0xFF20C997);
  static const Color termRed     = Color(0xFFDC3545);
  static const Color termYellow  = Color(0xFFFFC107);
  static const Color termBlue    = Color(0xFF0D6EFD);
  static const Color termMagenta = Color(0xFF9B59B6);
  static const Color termCyan    = Color(0xFF17A2B8);

  // ── Bright variants (ANSI 256-color) ───────────────────────────────────────

  static const Color brightBlack   = Color(0xFF6C757D);
  static const Color brightWhite   = Color(0xFFFFFFFF);
  static const Color brightRed     = Color(0xFFFF6B6B);
  static const Color brightGreen   = Color(0xFF5EF0B0);
  static const Color brightYellow  = Color(0xFFFFD93D);
  static const Color brightBlue    = Color(0xFF74B9FF);
  static const Color brightMagenta = Color(0xFFBB8FCE);
  static const Color brightCyan    = Color(0xFF48C9B0);

  // ── Xterm palette (ANSI 16-color + special) ─────────────────────────────────

  static const Color xtermBlack         = Color(0xFF1A1D23);  // same as surface
  static const Color xtermWhite         = Color(0xFFE0E0E0);  // light gray for foreground
  static const Color xtermCursor        = Color(0xFF20C997);  // green cursor
  static const Color xtermBackground    = Color(0xFF0E1117);  // same as background
  static const Color xtermSearchHitFg   = Color(0xFF000000);  // black text on highlight
}