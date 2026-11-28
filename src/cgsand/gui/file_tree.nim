## file tree panel like in VSCode: shows the directory tree of the workspace
## root, folders are expanded/collapsed by click, files are opened by click

import std/[os, algorithm]
import pkg/sigui/[uibase, mouseArea, scrollArea, layouts, animations, windowCreation]
import pkg/toscel/[fonts, icons, transitions, colors, label]
import ../logic/[configuration, file_openers]
import ./breadcrumbs

type
  TreeEntry = object
    name: string
    path: string
    isDir: bool
    depth: int
    expanded: bool

  FileTree* = ref object of Uiobj
    rootPath*: Property[string]
      ## directory the tree displays
    currentFile*: Property[string]
      ## file highlighted as opened
    fileOpener* {.unprintable.}: Property[seq[FileOpener]]

    expandedDirs*: Property[seq[string]]
      ## full paths of folders that show their children (plus plain names
      ## from the default value, matching any folder with that name)

registerComponent FileTree


const
  treeFontSize = 13'f32
  treeIconSize = 13'f32
  treeRowHeight = 24'f32
  treeIndentStep = 16'f32
    # indent per nesting level; files reserve the same space for the chevron
    # as folders do, so icons of different rows stay aligned
  treeChevronSpace = 4 + treeIconSize + 4


proc `<`(a, b: TreeEntry): bool = a.name < b.name


proc visibleEntries(dir: string, depth: int, expandedDirs: seq[string], result: var seq[TreeEntry]) =
  ## entries of `dir`, descending into each expanded folder right after
  ## the folder itself, so children appear directly under it
  var folders: seq[TreeEntry] = @[]
  var files: seq[TreeEntry] = @[]

  for kind, path in walkDir(dir):
    # the default `expandedDirs` contains plain dir names, clicks add full paths
    let expanded = (path in expandedDirs or path.splitPath.tail in expandedDirs)
    if kind in {pcDir, pcLinkToDir}:
      folders.add(TreeEntry(name: path.splitPath.tail, path: path, isDir: true, depth: depth,
        expanded: expanded))
    else:
      files.add(TreeEntry(name: path.splitPath.tail, path: path, isDir: false, depth: depth))

  for folder in sorted folders:
    result.add folder
    if folder.expanded:
      visibleEntries(folder.path, depth + 1, expandedDirs, result)

  result.add sorted files


method init(this: FileTree) =
  procCall this.super.init()

  # default: show the examples folder expanded
  this.expandedDirs = @["examples"].property

  this.makeLayout:
    - UiRect.new:
      this.fill(parent)
      color = binding: colorTheme[].bgExplorer

    - Label.new:
      left = parent.left + 10
      centerY = parent.top + 16
      text = tr"Files"
      fontSize = 13
      color = binding: colorTheme[].fgMuted

    # note: the ScrollArea itself is created once — putting it into a changable
    # child would delete and recreate it (with its scroll state) on every
    # content change, resetting the scroll position (e.g. after opening a file);
    # the changable child holds only the rows
    - ScrollArea.new:
      left = parent.left
      right = parent.right
      top = parent.top + 32
      bottom = parent.bottom

      # when the content shrinks (a folder is collapsed, a smaller workspace
      # root is opened) or the panel itself shrinks, the saved scroll offset
      # can point past the content — clamp it, so the panel doesn't show a
      # blank area
      #
      # note: each rebuild of the changable child passes through a state where
      # the fresh empty Layout is the only child of the ScrollArea — it sends
      # ChildAdded, scrollH is recalculated as 0. Clamping in that state would
      # reset the scroll offset on every rebuild, so clamp only when there is
      # actual content
      on this.scrollH.changed:
        if this.scrollH[] > 0:
          this.targetY[] = this.targetY[].clamp(0, (this.scrollH[] - this.h[]).max(0))

      on this.h.changed:
        if this.scrollH[] > 0:
          this.targetY[] = this.targetY[].clamp(0, (this.scrollH[] - this.h[]).max(0))

      --- Layout.col:  # the tree, recreated when the root, opened file, folders or language change
        <--- {update}: root.rootPath[]; root.currentFile[]; root.expandedDirs[]; config.language[]

        var entries: seq[TreeEntry]
        try:
          visibleEntries(root.rootPath[], 0, root.expandedDirs[], entries)
        except CatchableError:
          discard

        for entryI, entry in entries:
          var entry = entry
          let entryPath = entry.path.absolutePath
          let isCurrent = root.currentFile[].absolutePath == entryPath
          let indent = entry.depth.float32 * treeIndentStep

          - MouseArea.new:
            # rows are stacked vertically by the Layout, the indent of the
            # row content is set on the icons and the text below
            this.fillHorizontal(root)
            h = treeRowHeight
            cursor = pointingHand

            - UiRect.new:
              this.fill(parent)
              color = binding:
                if isCurrent:
                  if parent.pressed[]: color_bg_accent_button_pressed[]
                  elif parent.hovered[]: color_bg_accent_button_hovered[]
                  else: color_bg_accent_button[]
                else:
                  if parent.pressed[]: color_bg_button_pressed[]
                  elif parent.hovered[]: color_bg_button_hovered[]
                  else: color_bg_button[]

              addTransition this.color

            if entry.isDir:
              - UiSvgImage.new:
                x = 4 + indent
                centerY = parent.center
                w = treeIconSize
                h = treeIconSize
                image = (if entry.expanded: "arrow-down".icon.svg else: "arrow-right".icon.svg)
                color = binding: colorTheme[].fgMuted

            - UiSvgImage.new:
              x = treeChevronSpace + indent
              centerY = parent.center
              w = treeIconSize
              h = treeIconSize
              image = (if entry.isDir: "folder".icon.svg else: "file".icon.svg)
              color = (if entry.isDir: folderIconColor(entry.path, false) else: fileIconColor(entry.path, false))

            - UiText.new:
              x = treeChevronSpace + treeIconSize + 6 + indent
              centerY = parent.center
              text = entry.name
              font = font_default.withSize(treeFontSize)
              color = binding:
                if isCurrent: color_fg_accent[]
                elif parent.pressed[] or parent.hovered[]: color_fg_active[]
                else: color_fg[]

              addTransition this.color

            on this.clicked:
              if entry.isDir:
                var dirs = root.expandedDirs[]
                if entry.expanded:
                  # the folder can be listed by a full path or by a plain name
                  # (the default expandedDirs uses plain names), remove both,
                  # otherwise the folder would stay expanded
                  let pathI = dirs.find(entry.path)
                  if pathI != -1: dirs.delete(pathI)
                  let nameI = dirs.find(entry.path.splitPath.tail)
                  if nameI != -1: dirs.delete(nameI)
                else:
                  dirs.add entry.path
                root.expandedDirs[] = dirs
              else:
                root.fileOpener[].open(Location(path: entry.path.absolutePath))

        # the rebuild replaces every row with new MouseAreas that haven't seen
        # any real mouse move event yet, so a row doesn't know the cursor is
        # over it and silently swallows the click that rebuilt the tree (e.g.
        # the second click on a folder at the same position); re-dispatch the
        # current mouse position to update hover states of the fresh tree
        let win = root.parentUiWindow
        if win != nil:
          win.syncScale()
          let mouseMove = new MouseMoveEvent
          mouseMove[] = MouseMoveEvent(window: win.siwinWindow, pos: win.mouseState.pos,
            kind: MouseMoveKind.move)
          win.recieve(WindowEvent(sender: win, event: mouseMove))
