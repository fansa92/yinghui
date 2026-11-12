import 'package:flutter/material.dart';

/// Desktop layout helpers (batch 2).
///
/// Wide means a desktop-sized window: width >= 1024. The shell's own
/// mobile/desktop switch (bottom nav vs NavigationRail) already uses
/// 800; 1024 is the stricter breakpoint for content layout only, so
/// tablets keep the phone-style single column.

/// True on a desktop-sized window.
bool isWideLayout(BuildContext context) =>
    MediaQuery.of(context).size.width >= 1024;

/// Centres [child] with a max width on wide screens instead of letting
/// it stretch full-width; on phones it is a plain pass-through.
class CenteredContent extends StatelessWidget {
  const CenteredContent({super.key, required this.child, this.maxWidth = 1000});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 1024) return child;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        );
      },
    );
  }
}

/// Two side-by-side columns on wide screens, one stacked column on
/// phones. Used for the episode media-info sections and the download
/// detail info blocks.
class ResponsiveTwoColumn extends StatelessWidget {
  const ResponsiveTwoColumn({
    super.key,
    required this.first,
    required this.second,
    this.spacing = 16,
  });

  final Widget first;
  final Widget second;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 1024) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              first,
              SizedBox(height: spacing),
              second,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: first),
            SizedBox(width: spacing),
            Expanded(child: second),
          ],
        );
      },
    );
  }
}

/// Grid column count that grows on wide screens: 2 on phones,
/// 4 on desktop. Mobile behaviour is unchanged.
int gridColumnsForWidth(double width) => width >= 1024 ? 4 : 2;
