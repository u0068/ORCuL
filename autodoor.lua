-- Autoclosing door controller wiring instructions:
-- in1: connect to door state out.
-- in2: connect to motion sensor, detecting doorway obstruction.
-- in3: lock (door unlocks in an emergency)
-- in4: o2 level on one side (optional)
-- in5: o2 level on other side (optional)
-- in6: water level on high priority side
-- in7: water level on low priority side
-- in8: monster detector
-- in8..32: connect to emergency sensors
--         (eg. water and fire detectors on both sides of the door).

-- out1: door set_state input.
-- out2: emergency lights.
-- out3: lock light

local lastClosedTime = 0
local stayOpenTime = 4
local minOpenTime = 1

inp = {}
function upd()
    local isClosed = inp[1] ~= 1
    local motionDetected = inp[2] == 1
	local isLocked = inp[3] or nil
	local o2LevelA = inp[4] or -1 --this lest us know when detectors arent plugged in
	local o2LevelB = inp[5] or -1
	local waterLevelA = inp[6] or -1
	local waterLevelB = inp[7] or -1
	local monsterDetected = inp[8] or nil
    local hasEmergency = false
    for i = 8, 32 do isEmergency = isEmergency or inp[i] == 1 end
    table.clear(inp)

	if isClosed then
		lastClosedTime = time() --self explanatory
	end
	
	if isEmergency then 
		out[2] = 1 --turn on emergency indicator
		if (not isClosed) and (not motionDetected) and time() - lastClosedTime >= minOpenTime then --should that be or instead?
			out[1] = 0 --close if noones around
		end
	else 
		out[2] = 0 --turn off emergency indicator when not in an emergency
		if isLocked then
			out[3] = 1 --turn on lock indicator
			out[1] = 0 --close the door
		else
			out[3] = 0 --turn off lock indicator when not locked
			if motionDetected then
				out[1] = 1 --opens the door for you
			end
			if o2LevelA ~= -1 and o2LevelB ~= -1 and math.abs(o2LevelA - o2LevelB) > 30 then
				out[1] = 1 --lets some fresh air in if its getting a bit stale
			end
		end
	end
	
	
	if (not isClosed) and (not motionDetected) and time() - lastClosedTime >= stayOpenTime then
		out[1] = 0 --close the door if its open and noone is around for long enough
	end
	
	if waterLevelA ~= -1 and waterLevelB ~= -1 and waterLevelA - waterLevelB >= 5 and not monsterDetected and not isLocked then
		out[1] = 1 --drain water from the high to low priority room
	end
end
