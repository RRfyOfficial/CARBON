using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Carbon.Companion;

/// <summary>
/// Tactura's signature shape: a rectangle with one 45° chamfered top-right corner,
/// a fill and a 1 px hairline. The child is clipped to the shape.
/// </summary>
public sealed class ChamferBox : Decorator
{
    public static readonly DependencyProperty FillProperty = DependencyProperty.Register(
        nameof(Fill), typeof(Brush), typeof(ChamferBox), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty StrokeProperty = DependencyProperty.Register(
        nameof(Stroke), typeof(Brush), typeof(ChamferBox), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty ChamferProperty = DependencyProperty.Register(
        nameof(Chamfer), typeof(double), typeof(ChamferBox),
        new FrameworkPropertyMetadata(10.0, FrameworkPropertyMetadataOptions.AffectsRender | FrameworkPropertyMetadataOptions.AffectsArrange));

    public static readonly DependencyProperty PaddingProperty = DependencyProperty.Register(
        nameof(Padding), typeof(Thickness), typeof(ChamferBox), new FrameworkPropertyMetadata(default(Thickness), FrameworkPropertyMetadataOptions.AffectsMeasure));

    public ChamferBox() => SnapsToDevicePixels = true;

    public Brush? Fill { get => (Brush?)GetValue(FillProperty); set => SetValue(FillProperty, value); }
    public Brush? Stroke { get => (Brush?)GetValue(StrokeProperty); set => SetValue(StrokeProperty, value); }
    public double Chamfer { get => (double)GetValue(ChamferProperty); set => SetValue(ChamferProperty, value); }
    public Thickness Padding { get => (Thickness)GetValue(PaddingProperty); set => SetValue(PaddingProperty, value); }

    protected override Size MeasureOverride(Size constraint)
    {
        var p = Padding;
        var horizontal = p.Left + p.Right;
        var vertical = p.Top + p.Bottom;
        if (Child is null) return new Size(horizontal, vertical);
        Child.Measure(new Size(Math.Max(0, constraint.Width - horizontal), Math.Max(0, constraint.Height - vertical)));
        return new Size(Child.DesiredSize.Width + horizontal, Child.DesiredSize.Height + vertical);
    }

    protected override Size ArrangeOverride(Size size)
    {
        var p = Padding;
        Child?.Arrange(new Rect(p.Left, p.Top, Math.Max(0, size.Width - p.Left - p.Right), Math.Max(0, size.Height - p.Top - p.Bottom)));
        Clip = Shape(size, Chamfer, 0);
        return size;
    }

    protected override void OnRender(DrawingContext context) =>
        context.DrawGeometry(Fill, Stroke is null ? null : new Pen(Stroke, 1), Shape(RenderSize, Chamfer, 0.5));

    private static Geometry Shape(Size size, double chamfer, double inset)
    {
        var (w, h) = (size.Width, size.Height);
        var c = Math.Min(chamfer, Math.Min(w, h) / 2);
        var geometry = new StreamGeometry();
        using (var g = geometry.Open())
        {
            g.BeginFigure(new Point(inset, inset), isFilled: true, isClosed: true);
            g.LineTo(new Point(w - c - inset / 2, inset), true, false);
            g.LineTo(new Point(w - inset, c + inset / 2), true, false);
            g.LineTo(new Point(w - inset, h - inset), true, false);
            g.LineTo(new Point(inset, h - inset), true, false);
        }
        geometry.Freeze();
        return geometry;
    }
}
