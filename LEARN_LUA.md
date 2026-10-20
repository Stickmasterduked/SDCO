# Lua Basics for This Game (zero experience needed)

## 1. Functions and parameters

```lua
local function TestingFunction(Test1, Test2)
    print(Test1 + Test2)
end

TestingFunction(5, 10) -- prints 15
```

- `local function TestingFunction(...)`: makes a recipe named `TestingFunction`.
- `Test1` and `Test2` are **parameters**. They're empty slots, kind of like blanks on a form.
- You fill the slots when you **call** the function: `TestingFunction(5, 10)` means `Test1 = 5` and `Test2 = 10`.
- **How do you know what they do?** The name tells you nothing on its own. You find out by
  1. reading the code *inside* the function to see how the slot gets used, or
  2. reading the comment above it. Every function in this game has a comment like:

```lua
-- tween(object, seconds, goals)
--   object  = the thing to animate
--   seconds = how long it takes
--   goals   = what it should end up looking like
```

A real example from the game:

```lua
local function formatNumber(n)   -- n = any number
    if n >= 1000 then
        return (n / 1000) .. "K"  -- 1500 -> "1.5K"
    end
    return tostring(n)            -- small numbers stay as-is
end

formatNumber(1500) -- gives back "1.5K"
```

`return` means "hand this answer back to whoever called me".

## 2. Loops: `for i, v in pairs(...)`

```lua
for i, v in pairs(workspace:GetChildren()) do
    if v.Name == "Coin" then
        v:Destroy()
    end
end
```

- `workspace:GetChildren()` gives back a **list** of everything inside workspace.
- `for ... in pairs(list) do` repeats the code inside **once for each item**.
- Each time round, `i` = the item's position (1, 2, 3...) and `v` = the item itself.
- `i` and `v` are just nicknames. `for index, part in pairs(...)` works exactly the same way.
- `if v.Name == "Coin" then`: **two** `=` signs means *"is it equal?"* (a question).
  **One** `=` means *"set it to"* (an action). Writing `if x = true` is an error.
- `end` closes the `if`, and the second `end` closes the `for`.

## 3. Why we "grab" functions and services

```lua
local TweenService = game:GetService("TweenService")
```

Roblox ships with toolboxes called services. This line goes and fetches the animation toolbox
and keeps it in a variable, so later we can write `TweenService:Create(...)`
instead of fetching it again every time.

`:` vs `.`: use `:` when *calling a function that belongs to the object*
(`part:Destroy()`), and `.` when *reading or setting a property* (`part.Name`).

## 4. Events: `:Connect(function() ... end)`

```lua
button.MouseButton1Click:Connect(function()
    print("clicked!")
end)
```

`MouseButton1Click` is an **event**, meaning something that happens. `:Connect(...)` tells Roblox
"when that happens, run this function." The `)` after `end` closes the `Connect(`.

## 5. Tables (boxes with labeled slots)

```lua
local Data = { Coins = 0, Gems = 5 }
Data.Coins = Data.Coins + 10  -- now 10
print(Data["Gems"])           -- 5   (same as Data.Gems)
```

## 6. Where to change things in the game

Open `AnimeIncrementalGame` and look at **section 2. SETTINGS**:

| You want to...            | Change this        |
|---------------------------|--------------------|
| Add a hatchable character | `CHARACTERS`       |
| Add a chapter/enemy       | `CHAPTERS`         |
| Change egg prices         | `EGGS`             |
| Add a shop upgrade        | `UPGRADES`         |
| Hook up real gamepasses   | `GAMEPASSES` → `Id`|
| Add pictures              | find `Image = ""` and put `"rbxassetid://123456"` |
