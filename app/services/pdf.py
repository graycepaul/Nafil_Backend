"""PDF generation for estate reports and statements (reportlab)."""

from datetime import date
from io import BytesIO

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

from app.schemas.reports import VisitorLogEntry

BRAND_BLUE = colors.HexColor("#00308F")


def build_visitor_report(
    estate_name: str,
    start_date: date,
    end_date: date,
    entries: list[VisitorLogEntry],
) -> bytes:
    """Render a visitor log report as a PDF and return the raw bytes."""
    buffer = BytesIO()
    doc = SimpleDocTemplate(
        buffer,
        pagesize=A4,
        leftMargin=18 * mm,
        rightMargin=18 * mm,
        topMargin=18 * mm,
        bottomMargin=18 * mm,
        title=f"Visitor Report: {estate_name}",
    )
    styles = getSampleStyleSheet()
    story = [
        Paragraph(f"<b>{estate_name}</b>", styles["Title"]),
        Paragraph(
            f"Visitor log: {start_date:%d %b %Y} – {end_date:%d %b %Y}",
            styles["Normal"],
        ),
        Spacer(1, 8 * mm),
    ]

    rows = [["Visitor", "Vehicle", "Method", "Checked in", "Checked out"]]
    for entry in entries:
        rows.append(
            [
                entry.visitor_name,
                entry.vehicle_plate or "N/A",
                entry.method,
                f"{entry.checked_in_at:%d/%m %H:%M}",
                f"{entry.checked_out_at:%d/%m %H:%M}"
                if entry.checked_out_at
                else "on-site",
            ]
        )

    table = Table(rows, repeatRows=1, hAlign="LEFT")
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), BRAND_BLUE),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
                ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
                ("FONTSIZE", (0, 0), (-1, -1), 9),
                ("GRID", (0, 0), (-1, -1), 0.25, colors.HexColor("#DEE1E6")),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                (
                    "ROWBACKGROUNDS",
                    (0, 1),
                    (-1, -1),
                    [colors.white, colors.HexColor("#F7F8FA")],
                ),
                ("PADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )
    story.append(table)

    if not entries:
        story.append(Spacer(1, 6 * mm))
        story.append(Paragraph("No visitor activity in this period.", styles["Italic"]))

    doc.build(story)
    return buffer.getvalue()
