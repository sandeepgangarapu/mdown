public enum WelcomeMarkdown {
    public static let text = #"""
    # Welcome to MDown

    MDown keeps your Markdown typeset while you work. Click any paragraph, heading, list, or table to see the Markdown it is written in and change it. Press Escape, or click outside it, to set it again.

    ## Writing

    Type the way you would in any editor. Return starts a new paragraph, and inside a list it starts the next item. Return on an empty item ends the list. The arrow keys move from one block to the next, so the page reads as one document.

    Use **bold**, *italic*, ~~strikethrough~~, and `inline code`. Links open in your browser, like [CommonMark](https://commonmark.org/help/).

    > The Format menu and the toolbar style the block you're editing. Title is Shift-Command-T, Heading is Shift-Command-H, and Body is Shift-Command-B.

    ## Lists

    - Bulleted lists start with a dash
    - Tab nests an item; Shift-Tab moves it back
      - Like this one

    1. Numbered lists count for you
    2. Return continues the numbering

    - [x] Click a circle to check off an item
    - [ ] Checklists are Shift-Command-L
    - [ ] Your own notes

    ## The sidebar

    | Section | What it shows |
    | --- | --- |
    | Open | Every open document. Click one to switch to it. |
    | Contents | This document's headings. Click one to jump there. |
    | Folder | The Markdown files and folders around this one. The arrow goes up a folder. |
    | Recent | Files you opened before. |

    A file you click in Folder or Recent opens in this window and stays in Open until you close it. Command-click opens it in a new window. Choose which sections appear in Settings, and hide or show the sidebar with Control-Command-S.

    ## Code

    ```swift
    struct Note {
        var title: String
        var body: String
    }

    let note = Note(title: "MDown", body: "Hello")
    ```

    ## Pictures

    ![A paper swatch](bundle://SampleBanner)

    ---

    Change the typeface, size, and page color in Settings. Zoom with Command-Plus and Command-Minus.
    """#
}
