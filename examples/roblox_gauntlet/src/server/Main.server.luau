--!strict
-- Prism Gauntlet's one server script: build the course, then start the rules. (The modules beside it do the work:
-- Course builds, Style says how it looks, Rules runs the game, Debug helps a tester set things up.)

local Course = require(script.Parent:WaitForChild("Course"))
local Rules = require(script.Parent:WaitForChild("Rules"))

Course.build()
Rules.start()
