# `ui/` — Slate Shared Declarative Slint Component Library

`ui/` contains Slate's 63 declarative **[Slint](https://slint.dev)** components and layouts, plus the barrel export [`ui/index.slint`](index.slint). Every component in this directory is designed for **dual-target execution**:
1. **Native Desktop Rendering** via [`slint-d`](../slint-d/README.md) and [`slate:ui`](../slate-dlang/packages/ui/README.md).
2. **Reactive Web Compilation** to SolidJS (`.tsx`) + TypeScript (`.ts`) via [`slate:solid`](../slate-dlang/packages/solid/README.md) (`just solid-codegen`).

See [`ui/AGENTS.md`](AGENTS.md) for component authoring rules, `SlateTheme` token conventions, and accessibility requirements.

---

## Structure

| Path | Count | Description |
|---|---|---|
| [`ui/index.slint`](index.slint) | 1 | Barrel module re-exporting all components, data structs, layouts, and `SlateTheme` |
| [`ui/components/theme.slint`](components/theme.slint) | 1 | `SlateTheme` global singleton (dark/light mode palettes, spacing, radii, typography, durations) |
| [`ui/components/*.slint`](components/) | 46 | Reusable controls, forms, data grids, tree views, vector charts, media player, file dialog, overlays, and feedback widgets |
| [`ui/layouts/*.slint`](layouts/) | 16 | Structural application shells and workspace layouts (`SlateWindow`, `SlateDockLayout`, `SlateMasterDetailLayout`, `SlateWizardLayout`, `SlateBentoGrid`, etc.) |

---

## Component Catalog

### 1. Primitives, Forms & Controls (`ui/components/`)
- **Buttons & Inputs**: `button.slint` (`SlateButton`), `input.slint` (`SlateInput`), `search_input.slint` (`SlateSearchInput`), `textarea.slint` (`SlateTextarea`), `checkbox.slint` (`SlateCheckbox`), `radio.slint` (`SlateRadio`), `switch.slint` (`SlateSwitch`), `slider.slint` (`SlateSlider`), `segmented_control.slint` (`SlateSegmentedControl`)
- **Navigation & Menus**: `tabs.slint` (`SlateTabs`), `menubar.slint` (`SlateMenubar`), `header_bar.slint` (`SlateHeaderBar`), `pagination.slint` (`SlatePagination`), `action_row.slint` (`SlateActionRow`), `accordion.slint` (`SlateAccordion`)
- **Data Display & Visualization**: `data_grid.slint` (`SlateDataGrid`), `table.slint` (`SlateTable`), `tree_view.slint` (`SlateTreeView`), `charts.slint` (`SlateBarChart`, `SlateLineChart`, `SlateDonutChart`), `sparkline.slint` (`SlateSparkline`), `stat_group.slint` (`SlateStatGroup`), `metric_card.slint` (`SlateMetricCard`), `kanban_board.slint` (`SlateKanbanBoard`), `timeline.slint` (`SlateTimeline`), `description_list.slint` (`SlateDescriptionList`), `tag_list.slint` (`SlateTagList`), `log_viewer.slint` (`SlateLogViewer`), `card.slint` (`SlateCard`), `avatar.slint` (`SlateAvatar`), `badge.slint` (`SlateBadge`), `icons.slint` (`SlateIcon`)
- **Media, Files & Drag-and-Drop**: `media_player.slint` (`SlateMediaPlayer`), `file_dialog.slint` (`SlateFileDialog`), `dropzone.slint` (`SlateDropzone`), `drag_drop.slint` (`SlateDraggable`, `SlateDropTarget`)
- **Overlays & Feedback**: `modal.slint` (`SlateModal`), `alert_dialog.slint` (`SlateAlertDialog`), `drawer.slint` (`SlateDrawer`), `sheet.slint` (`SlateSheet`), `popover.slint` (`SlatePopover`), `tooltip.slint` (`SlateTooltip`), `toast.slint` (`SlateToast`), `alert.slint` (`SlateAlert`), `progress_bar.slint` (`SlateProgressBar`), `skeleton.slint` (`SlateSkeleton`), `mcp.slint` (`SlateMcpStatusPill`)

### 2. Application & Workspace Layouts (`ui/layouts/`)
- **Workspace Shells**: `window.slint` (`SlateWindow`), `web_app_layout.slint` (`SlateWebAppLayout`), `dock_layout.slint` (`SlateDockLayout`), `three_panel_layout.slint` (`SlateThreePanelLayout`), `navigation_split_view.slint` (`SlateNavigationSplitView`), `master_detail_layout.slint` (`SlateMasterDetailLayout`), `resizable_panel_group.slint` (`SlateSplitView`)
- **Flows, Headers & Pages**: `wizard_layout.slint` (`SlateWizardLayout`), `page_header.slint` (`SlatePageHeader`, `SlateBreadcrumbs`), `toolbar_status_bar.slint` (`SlateToolbar`, `SlateStatusBar`), `preferences_page.slint` (`SlatePreferencesPage`, `SlatePreferenceGroup`), `status_page.slint` (`SlateStatusPage`), `form_layout.slint` (`SlateFormLayout`, `SlateFormField`), `bento_grid.slint` (`SlateBentoGrid`, `SlateBentoTile`), `wrap_layout.slint` (`SlateWrapLayout`), `collapsible.slint` (`SlateCollapsible`)
