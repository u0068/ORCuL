--overengineered reactor controller using Lua (ORCuL)
--version 2.4.3
--author: u0068 (h)

--[[ inputs:
in1 = load
in2 = fuel
in3 = power
in4 = charge
in5 = temperature
in6 = fuelPercent
in7 = wifi/terminal
in8 = condition
in9 = engine speed

outputs: 
out1 = fissionRate
out2 = turbineOutput
out3 = chargeRate
out4 = battery state
out5 = wifi to chat
out6 = wifi channel
out7 = shutdown
out8 = activate

-- for displays
out26 = time since last incident
out27 = condition light state
out28 = condition light color
out29 = fuel% color
out30 = battery charge% color
out31 = charge rate% color
out32 = temperature color
]]--

--variables
inp = {}

local maxPowerOutput = 5500
local maxChargeRate = 2250
local maxDischargeRate = 4500
local maxVm = 1.9
local voltageMultiplier = 1
local chargeRate = 0
local targetCharge = 90
local chargeRegulationSpeed = 1
local chargeRegulationSpeedClamp = 0.5 --0.7
local chargeRegulationThreshold = 1
local mode = "dynamic"
local prevMode = "dynamic"
local predictedTurbineOutput = maxPowerOutput / 2
local targetTurbineOutput = 0
local slack = 0
local dynamicDecayRate = 0.3
local fuelOverride = false
local forcedLowPower = false
local prevVm = 1
local prevMsg = {}
local channel = 0
local batteries = true
local targetChargeRate = 0
local incident = false

local min, max, floor, ceil, abs = math.min, math.max, math.floor, math.ceil, math.abs

--functions
local function setSubSpecs(subSpecs)
	if subSpecs == "cyclops" then
		maxPowerOutput = 5000
		maxVm = 1.9
		maxChargeRate = 2400
		maxDischargeRate = 4000
	elseif subSpecs == "corvus" then
		maxPowerOutput = 4500
		maxVm = 1.9
		maxChargeRate = 2250
		maxDischargeRate = 4500
	elseif subSpecs == "korwus" then
		maxPowerOutput = 5500
		maxVm = 1.9
		maxChargeRate = 2250
		maxDischargeRate = 4500
	else
		maxPowerOutput = 3000
		maxVm = 1.6
		maxChargeRate = 1600
		maxDischargeRate = 2000
	end
end
setSubSpecs("korwus")

local function clamp(val, minval, maxval) --does what it says on the tin
	return min(maxval, max(minval, val))
end

local function round(val, nearest)
	nearest = nearest or 1
	val = val / nearest
	return (floor(val + 0.5)) * nearest
end

local function msg(str, id, chn) --sends a message to wifi
	id = id or "generic"
	chn = chn or channel
	if str == prevMsg[id] then
		-- do nothing
	else
		out[5] = str
		out[6] = chn
		prevMsg[id] = str
		print(str)
	end
end

local function rgbaToString(r, g, b, a)
	a = a or 255
	r, g, b = clamp(r, 0, 255), clamp(g, 0, 255), clamp(b, 0, 255)
	return table.concat({r, g, b, a}, ",")
end

local function hsvToRgb(h, s, v, a)
	a = a or 1
		local k1 = v*(1-s)
		local k2 = v - k1
		local r = clamp(3*abs(((h			)/180)%2-1)-1, 0, 1)
		local g = clamp(3*abs(((h	-120)/180)%2-1)-1, 0, 1)
		local b = clamp(3*abs(((h	+120)/180)%2-1)-1, 0, 1)
		r, g, b = k1 + k2 * r, k1 + k2 * g, k1 + k2 * b
	return rgbaToString(r * 255, g * 255, b * 255, a * 255)
end

function upd()
	--store the inputs
	local _load, fuelPotential, powerOutput, charge, temperature, fuelPercent, condition = inp[1], inp[2], inp[3], inp[4] or 0, inp[5] or 0, inp[6] or 100, inp[8] or 100
	local textInput = inp[7]
	if textInput then
		textInput = string.lower(textInput) --so that commands arent case sensitive
	else
		textInput = ""
	end
	incident = false
	local vmCap = abs(inp[9] or 100) / 100 --since the overvoltage only positively affects the engine and pumps, we only overvolt proportionally to how much the engine is being driven
	actualVoltageMultiplier = min(1 + (voltageMultiplier - 1) * vmCap, voltageMultiplier, maxVm) --we also cap it so our junction boxes dont get fried
	if string.find(textInput, ": ") ~= nil then --also parse commands in the format "PLACE: COMMAND" for use with teminals
		textInput = string.match(textInput, ": (.*)$")
	else
		textInput = string.match(textInput, "^(.*)") --this is unneccessary tbh
	end
	cmd, arg = string.match(textInput, "^(%a+) ?(.*)")
	if arg then
		if arg == "?" then
			arg, cmd	= cmd, "query" --this lets you query by typing something like "mode ?" is the same as "query mode"
		end
		if cmd == "reactor" then
			if arg == "off" then
				msg("Shutting down reactor", "Reactor")
				out[7] = 1
			elseif	arg == "on" then
				msg("Starting up reactor", "Reactor")
				out[8] = 1 --to turn on reactors remotely you need enhanced reactors mod
			end 
		elseif cmd == "power" then --power refers to both reactor and batteries
			if arg == "off" then
				msg("Shutting down all power", "Reactor")
				voltageMultiplier, prevVm = 0, voltageMultiplier --simplest way to turn all power off is to set voltage to 0 and let the rest of the code figure it out
				out[7] = 1
			elseif	arg == "on" then
				msg("Starting up all power", "Reactor")
				voltageMultiplier = prevVm
				out[8] = 1
			end 
		end
		arg = tonumber(arg) or string.lower(arg) or arg --try to turn arg into a number. making it lowercase again is probably unneccessary
		if type(arg) == "number" then
			if cmd == "vm" then voltageMultiplier = arg
			elseif cmd == "tc" then targetCharge = arg
			elseif cmd == "ch" then channel = arg; out[6] = arg
			elseif cmd == "crs" then chargeRegulationSpeed = arg
			elseif cmd == "sl" or cmd == "slack" then slack = arg
			elseif cmd == "dr" then dynamicDecayRate = arg
			elseif cmd == "mvm" then maxVm = arg
			elseif cmd == "mpo" then maxPowerOutput = arg
			elseif cmd == "mcr" then maxChargeRate = arg
			elseif cmd == "mdr" then maxDischargeRate = arg
			end
			msg("Command recieved", "Query") --confirms that the command was recieved
		end
		if cmd == "echo" then --echoes back what you tell it to. useful for making sure its recieving properly
			msg(arg, "Query")
		end
		if cmd == "ss" then setSubSpecs(arg) end --use some of the preset sub specs
		local modeList = {"prev", "dynamic", "low power", "flank", "fixed", "idle", "manual", "repair"}
		if cmd == "mode" then
			modeIndex = tonumber(arg) --example: "mode 1" sets the mode to dynamic
 			if modeIndex ~= nil then
				arg = modeList[modeIndex]
			elseif string.find("setup", arg) then arg = "idle"
			elseif string.find("efficient", arg) then arg = "low power"
			elseif string.find("default", arg) then arg = "dynamic"; voltageMultiplier, prevVm = 1, voltageMultiplier
			else
				for i, j in ipairs(modeList) do
					if string.find(j, arg) then --using string.find so its more forgiving of spelling mistakes and accepts abbreviations like "mode dyn" instead of "mode dynamic"
						arg = j
					end
				end
			end
			if arg == "flank off" and mode == "flank" then --use this for turning flank off from the nav terminal
				prevMode, mode, prevVm, voltageMultiplier = mode, prevMode, voltageMultiplier, prevVm
			end
			if arg == "prev" then
				mode, prevMode = prevMode, mode
				if prevMode == "low power" or prevMode == "flank" then
					prevVm, voltageMultiplier = voltageMultiplier, prevVm
				end
				if prevMode == "low power" then
					prevSlack, slack = slack, prevSlack
				end
			elseif arg == "low power" then
				prevMode, mode, prevVm, voltageMultiplier, prevSlack, slack = mode, "low power", voltageMultiplier, 0.6, slack, 0
			elseif arg == "flank" then
				prevMode, mode, prevVm, voltageMultiplier = mode, "flank", voltageMultiplier, maxVm
				--msg("Full speed ahead")
			else
				prevMode, mode = mode, arg
			end
			if arg == "repair" then
				out[7] = 0 --turns off reactor for repairs
			end
			msg("Switching mode from "..prevMode.." to "..mode,"Query")
		end
		if cmd == "query" then --query command lets you query the state of the system
			if arg == "fuel" then msg("Fuel: "..fuelPercent.."%","Query")
			elseif arg == "charge" then msg("Battery Charge: "..charge.."%","Query")
			elseif arg == "load" then msg("Load: ".._load.."kW","Query")
			elseif arg == "power" then msg("Power Output: "..powerOutput.."kW","Query")
			elseif arg == "temperature" then msg("Temperature: "..temperature.." degrees","Query")
			elseif arg == "condition" then msg("Condition: "..condition.."%","Query")
			elseif arg == "charge rate" then msg("Charge Rate: "..round(chargeRate,10).."%","Query")
			elseif arg == "channel" then msg("Channel: "..channel,"Query")
			elseif arg == "override" then msg("Fuel Override: "..tostring(fuelOverride)"Query")
			elseif arg == "slack" then msg("Slack: "..slack,"Query")
			elseif arg == "decayrate" then msg("Dynamic Decay Rate: "..dynamicDecayRate,"Query")
			elseif arg == "mode" then msg("Mode: "..mode,"Query")
			elseif arg == "vm" then msg("Voltage Multiplier: "..voltageMultiplier,"Query")
			elseif arg == "bat" then msg("Using Batteries: "..tostring(batteries),"Query")
			elseif arg == "all" then
				msg(
				"Channel: "..channel.."\n"..
				"Fuel Override: "..tostring(fuelOverride).."\n"..
				"Fuel: "..fuelPercent.."%\n"..
				"Battery Charge: "..charge.."%\n"..
				"Load: ".._load.."kW\n"..
				"Power Output: "..powerOutput.."kW\n"..
				"Required Power: "..targetPowerOutput.."kW\n"..
				"Temperature: "..temperature.." degrees\n"..
				"Condition: "..condition.."%\n"..
				"Charge Rate: "..round(chargeRate,10).."%\n"..
				"Mode: "..mode,
				"Query")
			end
		end
		if cmd == "ping" then
			msg("pong", "Query")
		end
		if cmd == "prime" and (mode == "dynamic" or mode == "flank") then
			targetTurbineOutput = 100 --this lets the reactor quickly respond to demand spikes in the near future by increasing slack ahead of time
			msg("Preparing for action", "Reactor")
		end
		if cmd == "ov" or cmd == "override" then --stops low power mode from being forced when fuel is low
			if arg == "off" then
				fuelOverride = false
			elseif	arg == "on" then
				fuelOverride = true
			elseif not arg then
				fuelOverride = not fuelOverride
			end
			msg("Fuel Override: "..tostring(fuelOverride),"Query")
		end
		if cmd == "bat" or cmd == "batteries" then --turns batteries off
			if arg == "off" then
				batteries = false
			elseif	arg == "on" then
				batteries = true
			elseif not arg then
				batteries = not batteries
			end
			msg("Using Batteries: "..tostring(batteries),"Query")
		end
		if textInput == "there has been an incident" or textInput == "an incident has occured" then --lets you reset the incident timer from chat
			incident = true
		end
	end
	inp[7] = "" --clears the input when its done with it. this prevents it from continuously responding to a command

	-- We do a little trolling
	_, phrase = string.match(textInput, "([Ii]'?%s?a?m)%s(.+)")
	if phrase and phrase ~= "microlua component" then msg("Hi " .. phrase .. ", I'm MicroLua Component", "Trolling") end

	if batteries then
		--load regulating battery controller
		--when power > load charge batteries with the excess power
		--also calculates how much the batteries are discharging when power < load
		if actualVoltageMultiplier == 0 then
			powerSurplus = 0
		else
			powerSurplus = (powerOutput/actualVoltageMultiplier - _load)
		end
		
		--if actualVoltageMultiplier < 1 then powerSurplus = powerSurplus + 10 end --gives some wiggle room to prevent flickering lights and stuff
		
		if actualVoltageMultiplier == 0 then --dont discharge batteies when we dont want any power
			out[4] = 0
		elseif
			actualVoltageMultiplier >= 1 or powerOutput/_load < 0.4 then out[4] = 1 --discharge the batteries when power is too low
		else 
			out[4] = 0
		end
		
		--modify power output to charge/discharge batteries to keep their charge at target level
		--for example if the batteries are low, we make a bit more power than necessary which will cause the batteries to respond by increasing the charge rate, and vice versa for too high charge
		chargeDeficit = clamp(targetCharge - charge, -100, 100)
		if abs(chargeDeficit) > chargeRegulationThreshold then --adding a threshold so that its not too sensitive, otherwise its a bit annoying
			outputModifier = chargeDeficit * chargeRegulationSpeed
			if chargeDeficit < 0 then
				outputModifier = outputModifier * maxDischargeRate * chargeDeficit/(100-targetCharge) --higher max discharge rate means it can discharge more agressively
			else 
				outputModifier = outputModifier * maxChargeRate * -chargeDeficit/(targetCharge) --same logic here for charge rate
			end
			outputModifier = (maxChargeRate/10) * round(outputModifier * 10 / maxChargeRate)
			outputModifier = clamp(outputModifier, -maxChargeRate * chargeRegulationSpeedClamp, maxDischargeRate * chargeRegulationSpeedClamp) --clamps a bit smaller than max so there is space for load regulation	
		else
			outputModifier = 0
		end
		
		targetChargeRate = clamp(targetChargeRate + actualVoltageMultiplier*powerSurplus*35/maxChargeRate, 0, 100)
		if chargeRate ~= 10 * floor(targetChargeRate/10) then --batteries can only charge in multiples of 10% and we want our code to reflet that
			chargeRate = 10 * floor(targetChargeRate/10)
			targetChargeRate = chargeRate + 5 --i found this works better for me
		end
		
		out[3] = chargeRate
	else
		chargeRate = 0 --turns batteries off when they are off
		outputModifier = 0
		out[4] = 0
	end
	if mode == "idle" then
		chargeRate = 100 --steal power from stations
	end
	

	--reactor controller
	targetPowerOutput = (_load - maxChargeRate*chargeRate/100 - outputModifier ) * actualVoltageMultiplier --calculates how much power we need
	targetPowerPercent = clamp(targetPowerOutput / maxPowerOutput * 100, 0, 100) --converts to percentage
	powerPercent = clamp(powerOutput / maxPowerOutput * 100, 0, 100) --how much power are we actually making as a percentage
	tempPercent = temperature / 50 --more convenient to work with
	if tempPercent > powerPercent + fuelPotential / 75 then --checks if the turbine output is the limiting factor, so we can update our prediction with 100% accuracy
		predictedTurbineOutput = powerPercent + 1 --we need the + 1 because thats how the game calculates power output
	else
		predictedTurbineOutput = predictedTurbineOutput + clamp(targetTurbineOutput - predictedTurbineOutput, -1/3, 1/3) --accounting for the time it takes for the dials to move to the target positions
	end
	predictedTurbineOutput = clamp(predictedTurbineOutput, 0 ,100) --clamp it just in case

	if targetPowerPercent <= targetTurbineOutput and (mode == "dynamic" or mode == "flank") then
		targetTurbineOutput = clamp(targetTurbineOutput + (targetPowerPercent - targetTurbineOutput) * (dynamicDecayRate / 100) + slack / maxPowerOutput * 100, 0, 100) --dynamically adjust turbine output depending on past activity
	else
		targetTurbineOutput = clamp(targetPowerPercent + (slack / maxPowerOutput * 100), 0, 100) --make the required amount of power
	end

	targetTemperature = clamp(50 * min(targetPowerPercent, predictedTurbineOutput + 1), 0, 5000) --calculate what temperature we need to limit power to exactly what we need
	targetFissionRate = clamp((targetTemperature + 100 * predictedTurbineOutput) / (2 * fuelPotential), 0 ,100) --calculate what fission rate we need to reach that temperature

	if mode == "idle" or mode == "repair" or fuelPercent == 0 then
		fissionRate = 0 --we dont want to explode the reactor when being repaired or refueled
	else
		fissionRate = targetFissionRate
	end
	turbineOutput = targetTurbineOutput

	if targetPowerOutput > maxPowerOutput + maxDischargeRate then
		msg("Insufficient power", "Load") --both reactor and batteries at full power wont be enough to satisfy demand
	elseif targetPowerOutput > maxPowerOutput then
		msg("Reactor under high load", "Load") --reactor at full power still needs batteries to satisfy demand which isnt sustainable
	elseif targetPowerOutput <= maxPowerOutput/2 and mode ~= "flank" then
		msg("Reactor under normal load", "Load")
	end

	if temperature > 7965 then --this is the temperature at which a meltdown starts
		msg("Temperature Critical, Emergency Shutdown", "Temperature")
		incident = true --reactor going boom is bad
		out[7] = 1 --shuts down the reactor, can also turn an alarm on
	elseif temperature > 6000 then
		msg("Temperature High", "Temperature")
		fissionRate = 0 --prevent any further increase
	elseif temperature > 5000 then --temperature should never go above 5000 in normal operation
		fissionRate = fissionRate * ((6000 - temperature)/1000) -- soft cap on fission rate to not blow the reactor up
	elseif temperature <= 1 then
		msg("Reactor cold", "Temperature")
	else
		msg("Temperature Normal", "Temperature")
	end
	
	fuelRodPercent = fuelPercent / 4 --this is intended to run on 4 fuel rods 
	if fuelPercent <= 1 then
		msg("No Fuel", "Fuel")
		--incident = true --not really an incident because we still have batteries
	elseif fuelRodPercent < 8 then
		if fuelOverride then
			msg("Fuel Critical", "Fuel")
		else
			msg("Fuel Critical, Reducing power usage", "Fuel")
			prevMode, mode, prevVm, voltageMultiplier, prevSlack, slack = mode, "low power", voltageMultiplier, 0.6, slack, 0
			forcedLowPower = true --forces the reactur to be as efficient as possible, undervolting the sub
		end
	elseif fuelRodPercent < 15 then
		msg("Fuel Very Low", "Fuel")
	elseif fuelRodPercent < 30 then
		msg("Fuel Low", "Fuel")
	elseif fuelRodPercent == 50 then
		msg("Fuel at 50%", "Fuel")
	elseif fuelRodPercent > 70 then
		if mode == "low power" and forcedLowPower then
			msg("Reactor refuelled, Returning to normal operation", "Fuel")
			prevMode, mode, prevVm, voltageMultiplier, prevSlack, slack	= mode, prevMode, voltageMultiplier, prevVm, slack, prevSlack
			forcedLowPower = false --stops forcing low powr since there is a good amount of fuel
		else
			msg("Reactor refuelled", "Fuel")
		end
	else
		msg("", "Fuel") --this prevents message spam i think
	end

	if condition < 10 then
		msg("Condition Critical, Emergency Shutdown", "Condition")
		incident = true --exploding reactor is bad
		out[7] = 1 --this turns the reactor off. could also be used to sound an alarm
	elseif condition < 50 then
		msg("Condition low", "Condition")
	elseif condition < 75 then
		msg("Reactor leaking", "Condition") --if using enchanced reactors
	elseif condition < 80 then
		msg("Condition at 80%", "Condition") --reactor becomes repairable
	elseif condition >= 99 then
		if mode == "repair" then --for enhanced reactors
			msg("Condition at 100%, powering up reactor", "Condition")
			mode, prevMode = prevMode, mode --switches back to whatever mode it was before
			out[8] = 1 --automatically turns reactor on when its done repairing
		else
			msg("Condition at 100%, remember to turn on the reactor", "Condition")
		end
	end

	if charge <= 1 then
		msg("Batteries Empty", "Batteries")
		incident = true --empty batteries is usually very bad, and with ORCuL it usually also means your reactor is not running so there is no power which is why this is counted as an incident
	elseif charge <= 30 then
		msg("Battery Charge Low", "Batteries")
	elseif charge > 50 + targetCharge/2 + chargeRegulationThreshold then
		msg("Battery Charge High", "Batteries") --charge is too high above the target charge, which means not as much excess power can be absorbed
	elseif abs(charge - targetCharge) <= chargeRegulationThreshold then
		msg("Battery Charge Optimal", "Batteries")
	end

	if mode ~= "low power" then
		forcedLowPower = false --stop forcing low power when not in low power mode
	end

	if mode ~= "manual" then
		out[1] = fissionRate
		out[2] = turbineOutput
	end
	
	--text for displays
	out[20] = string.upper(mode)
	if incident then
		out[26] = 1 --resets the 'time since last incident' if there has been an incident. you could also use this to turn on an alarm
	else 
		out[26] = 0 
	end
	
	--colors for displays
	out[29] = hsvToRgb(fuelPercent * 0.3, 1, 1) --fuel, red is low green is high
	out[30] = hsvToRgb(clamp(charge/targetCharge * 120, 0, 350), 1, 1) --battery charge, red is low, geen is optimal, blue/purple is too high
	out[31] = hsvToRgb((chargeRate/100)^2 * 120 + 180, chargeRate/100, 1) --charge rate, white is low blue is medium purple is high
	out[32] = rgbaToString(temperature * 0.04, temperature * 0.02, 255 - temperature * 0.04, 100) --temperature, blue is cold and yellow is hot
	if condition < 75 then --this makes condition light get even closer to red when the reactor starts leaking (enhanced reactors)
		out[28] = hsvToRgb(120 * (condition * 0.01)^2, 1, 1, 0.3) --red is low, yellow is repairable
	else
		out[28] = hsvToRgb(130 * (condition * 0.01)^2, 1, 1, 0.3) --greener is higher
	end

	if condition < 80 then --only turn on condition light when repairable
		out[27] = 1
	else
		out[27] = 0
	end
end