// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

extension Color {
    /// The teal the shell marks things with: the ring around a listening figure, the hover
    /// ring, and the symbol beside a recognised sentence.
    ///
    /// Darker than the teal the figure itself is drawn in
    /// (`FigurePalette.signal`, 0.204/0.753/0.663), and for one measured reason. That brighter
    /// teal sits inside the dark body of the figure, where it reaches 6.05 : 1 and is right.
    /// The marks below sit on whatever is behind them — a light window material, a pale
    /// wallpaper — and there it managed 2.27 : 1 against white and 1.81 : 1 against the light
    /// material, under the 3 : 1 the HIG asks for a graphical element (`zahlen.md`, Text und
    /// Grafik: Kontrast).
    ///
    /// One colour rather than a pair for light and dark, because the ring's real backdrop is
    /// the desktop, and a wallpaper does not follow the appearance setting. This one was picked
    /// as the brightest teal of the same hue that clears 3 : 1 against **every** surface it can
    /// land on, measured with the WCAG relative-luminance formula:
    ///
    /// | Untergrund | Verhältnis |
    /// |---|---|
    /// | Weiß | 3,80 : 1 |
    /// | helles Material, etwa 0,90 grau | 3,03 : 1 |
    /// | dunkles Material, etwa 0,18 grau | 3,57 : 1 |
    /// | Körper der Figur, 0,153/0,180/0,216 | 3,61 : 1 |
    /// | Schwarz | 5,52 : 1 |
    static let companionSignal = Color(red: 0.157, green: 0.573, blue: 0.502)
}
