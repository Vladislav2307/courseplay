--[[
This file is part of Courseplay (https://github.com/Courseplay/courseplay)
Copyright (C) 2018 Peter Vajko

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]

AIDriver = {}
AIDriver.__index = AIDriver

AIDriver.slowAngleLimit = 20
AIDriver.slowAcceleration = 0.5
AIDriver.slowDownFactor = 0.5

--- Create a new driver
-- @param vehicle to drive. Will set up a course to drive from vehicle.Waypoints
function AIDriver:new(vehicle)
	local newAIDriver = {}
	setmetatable( newAIDriver, self )
	newAIDriver.vehicle = vehicle
	-- for now, initialize the course with the vehicle's current course
	newAIDriver.course = Course:new(vehicle, vehicle.Waypoints)
	newAIDriver.firstWaypointIx = 1
	newAIDriver.vehicle.cp.ppc:setAIDriver(newAIDriver)
	newAIDriver.vehicle.cp.ppc:enable()
	newAIDriver.acceleration = 1
	return newAIDriver
end

--- Start driving
-- @param ix the waypoint index to start driving at
function AIDriver:start(ix)
	self.firstWaypointIx = ix
	if self:isAlignmentCourseNeeded(ix) then
		self:setUpAlignmentCourse(ix)
	end
	if self.alignmentCourse then
		self.vehicle.cp.ppc:setCourse(self.alignmentCourse)
		self.vehicle.cp.ppc:setLookaheadDistance(PurePursuitController.shortLookaheadDistance)
		self.vehicle.cp.ppc:initialize(1, self)
	else
		self.vehicle.cp.ppc:setCourse(self.course)
		self.vehicle.cp.ppc:setLookaheadDistance(PurePursuitController.normalLookAheadDistance)
		self.vehicle.cp.ppc:initialize(ix, self)
	end
end

--- Main driving function
-- should be called from update()
function AIDriver:drive(dt)

	-- update current waypoint/goal point
	self.vehicle.cp.ppc:update()

	local allowedToDrive = true

	if self.vehicle.cp.ppc:atLastWaypoint() then
		if self:onAlignmentCourse() then
			-- alignment course to the first waypoint ended, start the actual course now
			self.vehicle.cp.ppc:setCourse(self.course)
			self.vehicle.cp.ppc:setLookaheadDistance(PurePursuitController.normalLookAheadDistance)
			self.vehicle.cp.ppc:initialize(self.firstWaypointIx, self)
			self.alignmentCourse = nil
			self:debug('Alignment course finished, starting course at waypoint %d', self.firstWaypointIx)
		elseif self.vehicle.cp.stopAtEnd then
			-- stop at the last waypoint
			allowedToDrive = false
			CpManager:setGlobalInfoText(self.vehicle, 'END_POINT')
		else
			-- continue at the first waypoint
			self.vehicle.cp.ppc:initialize(1, self)
		end
	end

	-- goal point to drive to
	local gx, gy, gz = self.vehicle.cp.ppc:getCurrentWaypointPosition()
	-- direction to the goal point
	local lx, lz = AIVehicleUtil.getDriveDirection(self.vehicle.cp.DirectionNode, gx, gy, gz);
	local moveForwards = true

	-- take care of reversing
	if self.vehicle.cp.ppc:isReversing() then
		local isReverseActive
		-- TODO: currently goReverse() calls ppc:initialize(), this is not really transparent,
		-- should be refactored so it returns a status telling us to drive forward from waypoint x instead.
		lx, lz, moveForwards, isReverseActive = courseplay:goReverse(self.vehicle, lx, lz)
		if not isReverseActive then
			-- goReverse is not driving, this is a simple case, use the direction calculated by our PPC.
			lx = -lx
			lz = -lz
		end
		-- otherwise we go wherever goReverse() is telling us to go
	end
	self:driveVehicle(dt, allowedToDrive, moveForwards, lx, lz, self:getSpeed())
end

---
function AIDriver:driveVehicle(dt, allowedToDrive, moveForwards, lx, lz, maxSpeed)
	AIVehicleUtil.driveInDirection(self.vehicle, dt, self.vehicle.cp.steeringAngle, self.acceleration,
		self.slowAcceleration, self.slowAngleLimit, allowedToDrive, moveForwards, lx, lz, maxSpeed, self.slowDownFactor);
end

function AIDriver:onWaypointChange(newIx)
	-- for backwards compatibility, we keep the legacy CP waypoint index up to date
	courseplay:setWaypointIndex(self.vehicle, newIx);
	-- rest is implemented by the derived classes
end


function AIDriver:getSpeed()
	-- override by the derived classes
	local speed
	if self.vehicle.cp.speeds.useRecordingSpeed then
		speed = self.course:getAverageSpeed(self.vehicle.cp.ppc:getCurrentWaypointIx(), 4)
	elseif self.vehicle.cp.ppc:isReversing() then
		speed = self.vehicle.cp.speeds.reverse or self.vehicle.cp.speeds.crawl
	end
	return speed and speed or 15
end

--- Is an alignment course needed to reach waypoint ix in the current course?
-- override in derived classes as needed
function AIDriver:isAlignmentCourseNeeded(ix)
	local d = self.course:getDistanceBetweenVehicleAndWaypoint(self.vehicle, ix)
	return d > self.vehicle.cp.turnDiameter and self.vehicle.cp.alignment.enabled
end

function AIDriver:onAlignmentCourse()
	return self.alignmentCourse ~= nil
end

function AIDriver:setUpAlignmentCourse(ix)
	local x, _, z = self.course:getWaypointPosition(ix)
	--Readjust x and z for offset being used
	-- TODO: offset should be an attribute of the course and handled by the course itself.
	if courseplay:getIsVehicleOffsetValid(self.vehicle) then
		x, z = courseplay:getVehicleOffsettedCoords(self.vehicle, x, z);
	end;
	-- TODO: maybe the course itself should return an alignment course to its own waypoint ix as we don't want
	-- to work with individual course waypoints here.
	local alignmentWaypoints = courseplay:getAlignWpsToTargetWaypoint(self.vehicle, x, z, math.rad( self.course:getWaypointAngleDeg(ix)))
	if not alignmentWaypoints then
		self:debug("Can't find an alignment course, may be too close to target wp?" )
		return
	end
	if #alignmentWaypoints < 3 then
		self:debug("Alignment course would be only %d waypoints, it isn't needed then.", #alignmentWaypoints )
		return
	end
	self:debug('Alignment course with %d started.', #alignmentWaypoints)
	self.alignmentCourse = Course:new(self.vehicle, alignmentWaypoints)
	self.alignmentCourse:print()
end

function AIDriver:debug(...)
	courseplay.debugVehicle(12, self.vehicle, ...)
end