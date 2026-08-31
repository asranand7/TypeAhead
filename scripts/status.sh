#!/bin/bash
# Is TypeAhead actually working?
#
# The honest test is not "is the process alive" — it is "has anything reached the
# store". Nothing can get into `vocab` unless the event tap is live and macOS has
# granted Accessibility, so a non-zero word count proves the whole chain.

DB="$HOME/Library/Application Support/TypeAhead/memory.sqlite"

echo "TypeAhead status"
echo "────────────────"

if pgrep -f "TypeAhead.app/Contents/MacOS/TypeAhead" >/dev/null; then
    echo "  process     ✅ running (PID $(pgrep -f 'TypeAhead.app/Contents/MacOS/TypeAhead' | head -1))"
else
    echo "  process     ❌ not running — open /Applications/TypeAhead.app"
    exit 1
fi

if [ ! -f "$DB" ]; then
    echo "  store       ❌ missing — the app has not finished starting"
    exit 1
fi

WORDS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM vocab;" 2>/dev/null || echo 0)
OBS=$(sqlite3 "$DB" "SELECT COALESCE(SUM(count),0) FROM ngram;" 2>/dev/null || echo 0)
SNIPPETS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM snippet WHERE count >= 3;" 2>/dev/null || echo 0)
SHOWN=$(sqlite3 "$DB" "SELECT COALESCE(SUM(shown),0) FROM feedback;" 2>/dev/null || echo 0)
ACCEPTED=$(sqlite3 "$DB" "SELECT COALESCE(SUM(accepted),0) FROM feedback;" 2>/dev/null || echo 0)
SAVED=$(sqlite3 "$DB" "SELECT COALESCE(SUM(chars_saved),0) FROM feedback;" 2>/dev/null || echo 0)

if [ "$WORDS" -gt 0 ]; then
    echo "  capturing   ✅ yes — Accessibility is granted and the tap is live"
else
    echo "  capturing   ⚠️  nothing yet"
    echo ""
    echo "  Either Accessibility is not granted, or suggestions are switched off."
    echo "  System Settings › Privacy & Security › Accessibility → enable TypeAhead,"
    echo "  then choose 'Suggestions On' from the menu bar icon."
    exit 0
fi

echo ""
echo "  learned     $WORDS words, $OBS observations, $SNIPPETS promoted phrases"
echo "  suggested   $SHOWN shown, $ACCEPTED accepted, $SAVED keystrokes saved"

if [ "$SHOWN" -eq 0 ]; then
    echo ""
    echo "  No suggestions offered yet. It needs evidence before it will guess:"
    echo "    • a word must be seen twice before it is completed"
    echo "    • a phrase must repeat three times before it is offered whole"
    echo "  Type a distinctive word twice, then start typing it again."
fi

echo ""
echo "  most-typed so far:"
sqlite3 "$DB" "SELECT '    ' || word || '  (' || count || '×)' FROM vocab ORDER BY count DESC, word LIMIT 8;" 2>/dev/null

# Words glued together are the signature of dropped keystrokes — see the tap
# re-enable path in KeyTap. Worth surfacing, because the data looks fine until
# you read it.
GLUED=$(sqlite3 "$DB" "SELECT COUNT(*) FROM vocab WHERE length(word) > 14;" 2>/dev/null || echo 0)
if [ "$GLUED" -gt 0 ]; then
    echo ""
    echo "  ⚠️  $GLUED suspiciously long 'words' — possibly merged across a dropped"
    echo "     keystroke. Inspect with:"
    echo "     sqlite3 \"\$HOME/Library/Application Support/TypeAhead/memory.sqlite\" \\"
    echo "       \"SELECT word FROM vocab WHERE length(word) > 14;\""
fi
