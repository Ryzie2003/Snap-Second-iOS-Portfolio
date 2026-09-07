//
//  QuoteBank.swift
//  Memoir
//
//  Library of quotes for reflective app surfaces.
//  First 50 are real literary/wisdom quotes with attribution,
//  last 50 are original, book-inspired lines written for Memoir.
//

import Foundation

struct QuoteBank {
    /// All quotes available to UI surfaces.
    /// Entries 0–49: real quotes with author.
    /// Entries 50–99: original Memoir-style lines.

    static let quotes: [String] = [
        // 1–50: REAL QUOTES (public-domain / classic / ancient)

        "“Every moment is a fresh beginning.” — T.S. Eliot",
        "“There is no charm equal to tenderness of heart.” — Jane Austen",
        "“We are such stuff as dreams are made on.” — William Shakespeare",
        "“Nothing is worth more than this day.” — Johann Wolfgang von Goethe",
        "“The earth has music for those who listen.” — William Shakespeare (attributed)",
        "“The soul becomes dyed with the color of its thoughts.” — Marcus Aurelius",
        "“What you think, you become.” — Buddha",
        "“Act as if what you do makes a difference. It does.” — William James",
        "“Where there is love, there is life.” — Mahatma Gandhi",
        "“Hope is the thing with feathers.” — Emily Dickinson",
        "“The future depends on what you do today.” — Mahatma Gandhi",
        "“Heaven is under our feet as well as over our heads.” — Henry David Thoreau",
        "“The sun is new each day.” — Heraclitus",
        "“In three words I can sum up everything I’ve learned about life: it goes on.” — Robert Frost",
        "“The only journey is the one within.” — Rainer Maria Rilke",
        "“We do not remember days, we remember moments.” — Cesare Pavese",
        "“Joy in looking and comprehending is nature’s most beautiful gift.” — Albert Einstein",
        "“All that we see or seem is but a dream within a dream.” — Edgar Allan Poe",
        "“The language of friendship is not words but meanings.” — Henry David Thoreau",
        "“To love and be loved is to feel the sun from both sides.” — David Viscott",
        "“The stars are always shining, even when we do not see them.” — Thomas Carlyle",
        "“Be faithful in small things because it is in them that your strength lies.” — Mother Teresa",
        "“Beauty is truth, truth beauty.” — John Keats",
        "“Nothing can bring you peace but yourself.” — Ralph Waldo Emerson",
        "“The most wasted of all days is one without laughter.” — Nicolas Chamfort",
        "“The heart has its reasons which reason knows not.” — Blaise Pascal",
        "“Silence is a source of great strength.” — Lao Tzu",
        "“There is pleasure in the pathless woods.” — Lord Byron",
        "“If light is in your heart, you will find your way home.” — Rumi",
        "“You are never too old to set another goal or dream a new dream.” — C.S. Lewis",
        "“What lies behind us and what lies before us are tiny matters compared to what lies within us.” — Ralph Waldo Emerson",
        "“Happiness is a perfume you cannot pour on others without getting some on yourself.” — Ralph Waldo Emerson",
        "“Begin, be bold, and venture to be wise.” — Horace",
        "“The mind is everything; what you think you become.” — Buddha",
        "“Light tomorrow with today.” — Elizabeth Barrett Browning",
        "“The clearest way into the Universe is through a forest wilderness.” — John Muir",
        "“A single gentle rain makes the grass many shades greener.” — Henry David Thoreau",
        "“The day is what you make it.” — Henry David Thoreau",
        "“We live but a fraction of a second.” — Jack London",
        "“The universe is full of magical things patiently waiting for our wits to grow sharper.” — Eden Phillpotts",
        "“A poet is a nightingale who sits in darkness and sings.” — Percy Bysshe Shelley",
        "“Life is the flower for which love is the honey.” — Victor Hugo",
        "“The measure of life is not its duration but its donation.” — Peter Marshall",
        "“It is not length of life, but depth of life.” — Ralph Waldo Emerson",
        "“There is a crack in everything, that’s how the light gets in.” — Leonard Cohen",
        "“To live is the rarest thing in the world. Most people exist, that is all.” — Oscar Wilde",
        "“Live as if you were to die tomorrow. Learn as if you were to live forever.” — Mahatma Gandhi",
        "“The best way out is always through.” — Robert Frost",
        "“All we have to decide is what to do with the time that is given us.” — J.R.R. Tolkien",
        "“It is never too late to be what you might have been.” — George Eliot",

        // 51–100: ORIGINAL, BOOK-INSPIRED MEMOIR LINES

        "There is quiet meaning hidden inside every ordinary day.",
        "Some moments stay with us not because they were loud, but because they were honest.",
        "You may forget today’s details, but some part of it will remember you.",
        "There is wisdom in the soft places where nothing seems to be happening.",
        "Today might be quieter than most, but quiet days have their own kind of light.",
        "A small truth can rise to the surface when the day slows down enough to hear it.",
        "Even the gentlest hour leaves a mark on the heart.",
        "You lived something today that won’t happen in the same way again.",
        "You might not see the meaning yet, but the day has already written its line.",
        "Somewhere in today’s chaos was a moment worth remembering.",
        "Let the day land softly—it has carried you farther than you think.",
        "Time has a way of choosing which moments stay with us.",
        "Even the unremarkable days shape us in quiet ways.",
        "Notice the things that made you pause, even if only for a breath.",
        "Sometimes the heart holds onto details the mind barely noticed.",
        "A calm moment today may become a warm memory tomorrow.",
        "Meaning often hides in the smallest corners of the day.",
        "Let today rest gently inside you—it doesn’t have to be perfect to matter.",
        "The day may be ending, but some part of it is still unfolding within you.",
        "You experienced something today that future you may come back to.",
        "The simplest hours often become the ones we treasure most.",
        "A single soft moment can brighten the whole memory of a day.",
        "There is a quiet kind of magic in noticing your own life.",
        "The day leaves traces—pay attention to the ones that feel warm.",
        "Not every day is remarkable, but each holds a fragment worth keeping.",
        "Moments become memories the second we choose to notice them.",
        "Let yourself slow down long enough to catch what the day is offering.",
        "Some moments become guideposts long after the day has passed.",
        "Even a fleeting feeling can become a cherished memory.",
        "Today brought you something—maybe small, maybe gentle, but yours.",
        "The day may have felt simple, yet simplicity often ages beautifully.",
        "You lived a whole story today, even if it didn’t feel like one.",
        "A thought worth saving might appear when you least expect it.",
        "Today’s quiet moments may mean more in hindsight.",
        "The heart often understands days the mind rushes through.",
        "Let the softest parts of today be the ones you carry forward.",
        "Every day, even the blurry ones, adds depth to who you are.",
        "There is a lesson hidden somewhere in the rhythm of today.",
        "You might not remember everything, but a piece of the day will stay with you.",
        "Even ordinary hours can shimmer when you look back on them.",
        "Within today’s routine, something quietly meaningful unfolded.",
        "Sometimes the day’s gift is simply that you made it through.",
        "You’ll understand some parts of today only much later.",
        "In every day lives a moment that asks to be noticed.",
        "What seems small now may be the moment you cherish most.",
        "Today wrote its chapter softly—read it again in your heart.",
        "There’s beauty in the edges of the day, where reflection begins.",
        "Life shifts in subtle ways; today may have moved something in you.",
        "The meaning of a day reveals itself slowly—give it time.",
        "You’ve collected another day in your story; hold it with kindness."
    ]

    /// Total number of quotes available.
    static var count: Int {
        quotes.count
    }

    /// Returns the quote at a given index, safely wrapped.
    static func quote(at index: Int) -> String {
        guard !quotes.isEmpty else { return "" }
        let safeIndex = (index % quotes.count + quotes.count) % quotes.count
        return quotes[safeIndex]
    }

    /// Returns a random quote and its index (no persistence yet).
    static func randomQuote() -> (index: Int, text: String) {
        guard !quotes.isEmpty else { return (0, "") }
        let idx = Int.random(in: 0..<quotes.count)
        return (idx, quotes[idx])
    }
}
