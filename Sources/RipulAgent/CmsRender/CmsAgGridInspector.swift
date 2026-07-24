import Foundation

/// Property schema for the AG Grid block — primarily scoped to the props the
/// NATIVE renderer consumes (CmsAgGridBlock.swift), so every edit in the native
/// inspector visibly changes the native render. Scalar web-parity knobs that
/// round-trip through the raw JSON save are also included (they affect the web
/// grid and keep the native inspector aligned with the web panel). Custom
/// editors (drag-reorder columns, column groups, agent mentions, export) stay
/// on the web designer for now; the framework takes any schema, so expanding is
/// adding descriptors.
enum CmsAgGridInspector {
    static let schema = CmsInspectorSchema(
        groups: [
            CmsPropertyGroup(id: "dataBinding", label: "Data Binding"),
            CmsPropertyGroup(id: "columns", label: "Columns"),
            CmsPropertyGroup(id: "native", label: "Native App"),
            CmsPropertyGroup(id: "layout", label: "Layout"),
            CmsPropertyGroup(id: "rows", label: "Rows"),
            CmsPropertyGroup(id: "header", label: "Header"),
            CmsPropertyGroup(id: "sorting", label: "Sorting"),
            CmsPropertyGroup(id: "filtering", label: "Filtering"),
            CmsPropertyGroup(id: "grouping", label: "Grouping & Totals"),
            CmsPropertyGroup(id: "grid", label: "Grid"),
        ],
        fields: [
            // Data binding
            CmsPropertyField(
                key: "querySlug", label: "Read query",
                kind: .queryRef(emptyLabel: "None"),
                group: "dataBinding",
                helperText: "Saved query that provides the grid data."
            ),

            // Columns — shared refs (diagnostic + editable)
            CmsPropertyField(
                key: "columnViewRef", label: "Column view ref",
                kind: .string(placeholder: "none"),
                group: "columns",
                helperText: "Slug of a shared Column View (schema-level). When set, columns come from the column view instead of the inline set below."
            ),
            CmsPropertyField(
                key: "columnDefsRef", label: "Column defs ref",
                kind: .string(placeholder: "none"),
                group: "columns",
                helperText: "Slug of a ColumnDefs block on this page (page-level). Falls back to when no Column View is set."
            ),
            CmsPropertyField(
                key: "columns", label: "Column order & settings",
                kind: .columns(querySlugKey: "querySlug"),
                group: "columns"
            ),
            CmsPropertyField(
                key: "nativeColumns", label: "Native column set",
                kind: .string(placeholder: "name, hours_worked, total_earning"),
                group: "columns",
                helperText: "Comma-separated column keys shown natively; blank shows all columns."
            ),
            CmsPropertyField(
                key: "autoSizeStrategy", label: "Auto-size strategy",
                kind: .select(options: [
                    CmsPropertyOption("none", "Manual"),
                    CmsPropertyOption("fitGridWidth", "Fit grid width"),
                    CmsPropertyOption("fitCellContents", "Fit cell contents"),
                ]),
                group: "columns"
            ),
            CmsPropertyField(
                key: "defaultColMinWidth", label: "Min column width",
                kind: .number(min: 40, max: 600, step: 10, unit: "px"),
                group: "columns"
            ),

            // Native App
            CmsPropertyField(
                key: "nativePresentation", label: "Presentation",
                kind: .select(options: [
                    CmsPropertyOption("auto", "Auto"),
                    CmsPropertyOption("list", "List"),
                    CmsPropertyOption("cards", "Cards"),
                    CmsPropertyOption("grid", "Grid"),
                ]),
                group: "native",
                default: .string("auto")
            ),
            CmsPropertyField(
                key: "nativeViewToggle", label: "Reader view toggle",
                kind: .boolean,
                group: "native",
                helperText: "Lets the reader switch between list, cards, and grid.",
                default: .bool(false)
            ),
            CmsPropertyField(
                key: "cardViewRef", label: "Cards design",
                kind: .cardViewRef(emptyLabel: "Auto (from columns)"),
                group: "native",
                helperText: "Shared card view used by the cards presentation."
            ),
            CmsPropertyField(
                key: "nativeScroll", label: "Scrolling",
                kind: .select(options: [
                    CmsPropertyOption("contained", "Contained"),
                    CmsPropertyOption("page", "Page"),
                ]),
                group: "native",
                helperText: "Contained scrolls inside the grid; Page scrolls with the page.",
                default: .string("contained")
            ),

            // Layout
            CmsPropertyField(
                key: "height", label: "Height",
                kind: .numberString(min: 100, max: 2000, step: 20, unit: "pt"),
                group: "layout",
                helperText: "Grid height for contained scrolling.",
                default: .string("400")
            ),

            // Rows
            CmsPropertyField(
                key: "fontSize", label: "Font size",
                kind: .number(min: 8, max: 24, step: 1, unit: "pt"),
                group: "rows",
                helperText: "Body cell font size; blank uses the renderer default.",
                default: .number(12)
            ),
            CmsPropertyField(
                key: "fontWeight", label: "Font weight",
                kind: .select(options: [
                    CmsPropertyOption("normal", "Normal"),
                    CmsPropertyOption("medium", "Medium"),
                    CmsPropertyOption("bold", "Bold"),
                ]),
                group: "rows",
                helperText: "Body cells; header and total rows have their own weight."
            ),
            CmsPropertyField(
                key: "rowHeight", label: "Row height",
                kind: .number(min: 20, max: 120, step: 2, unit: "px"),
                group: "rows",
                helperText: "Minimum body row height; blank sizes rows to content.",
                default: .number(30)
            ),
            CmsPropertyField(
                key: "rowBgColor", label: "Background",
                kind: .color,
                group: "rows"
            ),
            CmsPropertyField(
                key: "alternateRowColor", label: "Alternate row",
                kind: .color,
                group: "rows",
                helperText: "Only applies when row stripes are enabled.",
                visibleWhen: CmsPropertyVisibility(key: "enableRowStripes", equals: .bool(true))
            ),
            CmsPropertyField(
                key: "textColor", label: "Text color",
                kind: .color,
                group: "rows"
            ),
            CmsPropertyField(
                key: "enableRowStripes", label: "Alternating row stripes",
                kind: .boolean,
                group: "rows",
                default: .bool(true)
            ),
            CmsPropertyField(
                key: "rowSelectionMode", label: "Selection",
                kind: .select(options: [
                    CmsPropertyOption("none", "None"),
                    CmsPropertyOption("singleRow", "Single"),
                    CmsPropertyOption("multiRow", "Multi"),
                ]),
                group: "rows",
                default: .string("none")
            ),

            // Header
            CmsPropertyField(
                key: "headerFontSize", label: "Font size",
                kind: .number(min: 8, max: 24, step: 1, unit: "pt"),
                group: "header",
                default: .number(12)
            ),
            CmsPropertyField(
                key: "headerFontWeight", label: "Font weight",
                kind: .select(options: [
                    CmsPropertyOption("normal", "Normal"),
                    CmsPropertyOption("medium", "Medium"),
                    CmsPropertyOption("bold", "Bold"),
                ]),
                group: "header"
            ),
            CmsPropertyField(
                key: "headerBgColor", label: "Background",
                kind: .color,
                group: "header"
            ),
            CmsPropertyField(
                key: "headerTextColor", label: "Text color",
                kind: .color,
                group: "header"
            ),

            // Sorting / filtering
            CmsPropertyField(
                key: "enableSorting", label: "Enable sorting",
                kind: .boolean,
                group: "sorting",
                default: .bool(true)
            ),
            CmsPropertyField(
                key: "enableFiltering", label: "Enable filtering",
                kind: .boolean,
                group: "filtering",
                default: .bool(true)
            ),

            // Grouping & totals
            CmsPropertyField(
                key: "grandTotalRow", label: "Grand total row",
                kind: .select(options: [
                    CmsPropertyOption("none", "None"),
                    CmsPropertyOption("top", "Top"),
                    CmsPropertyOption("bottom", "Bottom"),
                ]),
                group: "grouping",
                default: .string("none")
            ),
            CmsPropertyField(
                key: "suppressGroupExpand", label: "Lock groups (no expand)",
                kind: .boolean,
                group: "grouping",
                default: .bool(false)
            ),
            CmsPropertyField(
                key: "groupRowBgColor", label: "Group row background",
                kind: .color,
                group: "grouping"
            ),
            CmsPropertyField(
                key: "groupRowTextColor", label: "Group row text",
                kind: .color,
                group: "grouping"
            ),
            CmsPropertyField(
                key: "groupRowFontWeight", label: "Group row weight",
                kind: .select(options: [
                    CmsPropertyOption("normal", "Normal"),
                    CmsPropertyOption("medium", "Medium"),
                    CmsPropertyOption("bold", "Bold"),
                ]),
                group: "grouping"
            ),
            CmsPropertyField(
                key: "groupRowFontSize", label: "Group row size",
                kind: .number(min: 8, max: 24, step: 1, unit: "pt"),
                group: "grouping",
                default: .number(12)
            ),
            CmsPropertyField(
                key: "grandTotalBgColor", label: "Grand total background",
                kind: .color,
                group: "grouping"
            ),
            CmsPropertyField(
                key: "grandTotalTextColor", label: "Grand total text",
                kind: .color,
                group: "grouping"
            ),
            CmsPropertyField(
                key: "grandTotalFontWeight", label: "Grand total weight",
                kind: .select(options: [
                    CmsPropertyOption("normal", "Normal"),
                    CmsPropertyOption("medium", "Medium"),
                    CmsPropertyOption("bold", "Bold"),
                ]),
                group: "grouping",
                helperText: "Falls back to the group row weight."
            ),
            CmsPropertyField(
                key: "grandTotalFontSize", label: "Grand total size",
                kind: .number(min: 8, max: 24, step: 1, unit: "pt"),
                group: "grouping",
                helperText: "Falls back to the group row size."
            ),

            // Grid
            CmsPropertyField(
                key: "accentColor", label: "Accent color",
                kind: .color,
                group: "grid"
            ),
        ]
    )
}
