-- Autoclosing door controller wiring instructions:
-- in1: connect to door state out.
-- in2: connect to motion sensor, detecting doorway obstruction.
-- in3..6: connect to emergency sensors
--         (eg. water and fire detectors on both sides of the door).
-- in7: o2 level on one side (optional)
-- in8: o2 level on other side (optional)
-- in9: lock

-- out1: door set_state input.
-- out2: emergency lights.

local lastClosedTime = 0
local stayOpenTime = 4
local minOpenTime = 1
local isLocked = false

inp = {}
function upd()
    local isClosed = inp[1] ~= 1
    local motionDetected = inp[2] == 1
	local o2LevelA = inp[7] or nil
	local o2LevelB = inp[8] or nil
    local hasEmergency = false
    for i = 3, 6 do hasEmergency = hasEmergency or inp[i] == 1 end
    table.clear(inp)

	if isClosed then
		lastClosedTime = time()
	end
	
	if hasEmergency then 
		out[2] = 1
		if not motionDetected and time() - lastClosedTime >= minOpenTime then
			out[1] = 0 --close 
		end
	else 
		out[2] = 0
		if motionDetected then
			out[1] = 1 --opens the door for you
		end
		if o2LevelA and math.abs(o2LevelA - o2LevelB) > 30 then
			out[1] = 1 --lets some fresh air in if its getting a bit stale
		end
	end
	
	if isLocked or ((not isClosed) and (not motionDetected) and time() - lastClosedTime >= stayOpenTime) then
		out[1] = 0
	end
end