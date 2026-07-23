-- spincard/layout — shared geometry constants for the card, so main.lua, card.lua
-- and images.lua can't drift on these magic numbers. The card is authored in a
-- fixed virtual ASS space; the box width + padding derive the inner content width
-- (used for text fitting and the clearlogo clamp on both the card and image sides).
return {
    RES_X = 1280, RES_Y = 720, -- ASS virtual canvas (osd-overlay res_x/res_y)
    CARD_W = 860,              -- card box width (virtual px)
    PAD    = 24,               -- card inner padding
    INNER  = 860 - 2 * 24,     -- inner content width (= CARD_W - 2*PAD = 812)
}
