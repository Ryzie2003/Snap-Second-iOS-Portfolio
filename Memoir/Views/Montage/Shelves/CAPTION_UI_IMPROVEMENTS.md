# Caption UI Improvements

## Summary
Redesigned the captions control panel to use a **mutually exclusive radio selection** for clearer UX. Users can choose ONE caption style at a time.

## Key Changes

### 1. **Mutually Exclusive Selection**
- Replaced independent toggle switches with a radio-button style selection
- Three options:
  - **None** - No captions on video
  - **Date Captions** - Show date & year on each clip
  - **Custom Text** - Add your own text overlay (Pro feature)

### 2. **New UI Components**

#### `CaptionSelection` Enum
Local enum to track the current selection state:
```swift
enum CaptionSelection: Equatable {
    case none
    case dates
    case custom
}
```

#### `CaptionOptionRow`
A radio-button style row that replaces the old toggle design:
- **Radio indicator**: Circle with filled dot when selected
- **Icon**: SF Symbol representing the option
- **Title and description**: Clear labeling with Pro badge support
- **Checkmark**: Visual confirmation on the right when selected
- **Visual feedback**: Border and background color change when selected

### 3. **Selection Logic**
The `selectCaptionType(_:)` function ensures mutual exclusivity:
- Selecting "None" clears both `showDates` and sets `captionMode = .none`
- Selecting "Date Captions" sets `showDates = true` and clears custom
- Selecting "Custom Text" sets `captionMode = .custom(text)` and clears dates

### 4. **Help Text**
Simplified help text that only appears when a caption type is selected:
- **Dates**: "Dates appear automatically on each clip"
- **Custom**: "Custom text appears on all clips"

## Visual Design

### Before (Confusing):
- Two independent toggle switches
- Both could be ON simultaneously
- Unclear which one takes precedence
- Toggle UI implied separate features

### After (Clear):
- Radio-button selection (only one active)
- Clear visual hierarchy with radio dots
- Checkmark confirms selection
- Custom editor only shows when "Custom Text" is selected

## UX Rationale

1. **Simplicity**: One caption type at a time is easier to understand
2. **Predictability**: What you select is what you get
3. **Familiar pattern**: Radio buttons are a well-understood selection paradigm
4. **Clean preview**: No confusion about overlapping captions
