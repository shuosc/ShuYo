/// A visible PPT snapshot with OCR text for one recorded lesson.
class VodPptSlide {
  const VodPptSlide({
    required this.id,
    required this.imageUrl,
    required this.position,
    required this.text,
  });

  final String id;
  final Uri? imageUrl;
  final Duration position;
  final String text;
}
