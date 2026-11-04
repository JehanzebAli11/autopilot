--!strict
-- The course's timing, worked out the same way on the server and on every client from the shared clock
-- (workspace:GetServerTimeNow()), so a laser, a phase block or a moving platform is in the same state for everyone and
-- can be predicted from its attributes: Period, OnSeconds and Offset (lasers, phase blocks), Travel, Dwell and Offset
-- (movers).

local Clock = {}

function Clock.now(): number
	return workspace:GetServerTimeNow()
end

-- Whether something on a cycle of `period` is in the first `onSeconds` of it, `offset` seconds late
function Clock.on(period: number, onSeconds: number, offset: number, t: number?): boolean
	local now = t or Clock.now()
	return (now - offset) % period < onSeconds
end

-- How far (0 at From, 1 at To) a mover is: it waits `dwell` at From, crosses in `travel` (eased), waits at To, crosses
-- back; a whole cycle is 2 (dwell + travel)
function Clock.mover(travel: number, dwell: number, offset: number, t: number?): number
	local now = t or Clock.now()
	local leg = dwell + travel
	local phase = (now - offset) % (2 * leg)
	local function ease(x: number): number
		return x * x * (3 - 2 * x)
	end
	if phase < dwell then
		return 0
	elseif phase < leg then
		return ease((phase - dwell) / travel)
	elseif phase < leg + dwell then
		return 1
	end
	return 1 - ease((phase - leg - dwell) / travel)
end

return Clock
