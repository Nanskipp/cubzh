local signup = {}

signup.startFlow = function(self, config)
	if self ~= signup then
		error("signup:startFlow(config) should be called with `:`", 2)
	end

	local conf = require("config")

	local defaultConfig = {
		ui = require("uikit"),
		onCancel = function() end,
		checkAppVersionAndCredentialsStep = function() end,
		signUpOrLoginStep = function() end,
		avatarPreviewStep = function() end,
		avatarEditorStep = function() end,
		loginStep = function() end,
		loginSuccess = function() end,
		dobStep = function() end,
		phoneNumberStep = function() end,
	}

	local ok, err = pcall(function()
		config = conf:merge(defaultConfig, config)
	end)
	if not ok then
		error("signup:startFlow(config) - config error: " .. err, 2)
	end

	local flowConfig = config

	local api = require("system_api", System)
	local ui = config.ui
	local flow = require("flow")
	local drawerModule = require("drawer")
	local ease = require("ease")
	local loc = require("localize")
	local phonenumbers = require("phonenumbers")
	local str = require("str")
	local bundle = require("bundle")

	local theme = require("uitheme").current
	local padding = theme.padding

	local signupFlow = flow:create()

	local animationTime = 0.3

	-- local backFrame
	local backButton
	local coinsButton
	local drawer
	local loginBtn

	local function showCoinsButton()
		if coinsButton == nil then
			local balanceContainer = ui:createFrame(Color(0, 0, 0, 0))
			local coinShape = bundle:Shape("shapes/pezh_coin_2")
			local coin = ui:createShape(coinShape, { spherized = false, doNotFlip = true })
			coin:setParent(balanceContainer)

			local l = LocalEvent:Listen(LocalEvent.Name.Tick, function(dt)
				coin.pivot.Rotation = coin.pivot.Rotation * Rotation(0, dt, 0)
			end)
			coin.onRemove = function()
				l:Remove()
			end

			local balance = ui:createText("100", { color = Color(252, 220, 44), textSize = "default" })
			balance:setParent(balanceContainer)
			balanceContainer.parentDidResize = function(self)
				local ratio = coin.Width / coin.Height
				coin.Height = balance.Height
				coin.Width = coin.Height * ratio
				self.Width = coin.Width + balance.Width + theme.padding
				self.Height = coin.Height

				coin.pos = { 0, self.Height * 0.5 - coin.Height * 0.5 }
				balance.pos = { coin.Width + theme.padding, self.Height * 0.5 - balance.Height * 0.5 }
			end
			balanceContainer:parentDidResize()

			coinsButton = ui:buttonMoney({ content = balanceContainer, textSize = "default" })
			-- coinsButton = ui:createButton(balanceContainer, { textSize = "default", borders = false })
			-- coinsButton:setColor(Color(0, 0, 0, 0.4))
			coinsButton.parentDidResize = function(self)
				ease:cancel(self)
				self.pos = {
					Screen.Width - Screen.SafeArea.Right - self.Width - padding,
					Screen.Height - Screen.SafeArea.Top - self.Height - padding,
				}
			end
			coinsButton.onRelease = function(_)
				-- display info bubble
			end
			coinsButton.pos = { Screen.Width, Screen.Height - Screen.SafeArea.Top - coinsButton.Height - padding }
			ease:outSine(coinsButton, animationTime).pos = Number3(
				Screen.Width - Screen.SafeArea.Right - coinsButton.Width - padding,
				Screen.Height - Screen.SafeArea.Top - coinsButton.Height - padding,
				0
			)
		end
	end

	local function removeCoinsButton()
		if coinsButton ~= nil then
			coinsButton:remove()
			coinsButton = nil
		end
	end

	local function showBackButton()
		if backButton == nil then
			backButton = ui:buttonNegative({ content = "⬅️", textSize = "default" })
			-- backButton = ui:createButton("⬅️", { textSize = "default" })
			-- backButton:setColor(theme.colorNegative)
			backButton.parentDidResize = function(self)
				ease:cancel(self)
				self.pos = {
					padding,
					Screen.Height - Screen.SafeArea.Top - self.Height - padding,
				}
			end
			backButton.onRelease = function(self)
				signupFlow:back()
			end
			backButton.pos = { -backButton.Width, Screen.Height - Screen.SafeArea.Top - backButton.Height - padding }
			ease:outSine(backButton, animationTime).pos =
				Number3(padding, Screen.Height - Screen.SafeArea.Top - backButton.Height - padding, 0)
		end
	end

	local function removeBackButton()
		if backButton ~= nil then
			backButton:remove()
			backButton = nil
		end
	end

	local createMagicKeyInputStep = function(config)
		local defaultConfig = {
			usernameOrEmail = "",
		}
		config = conf:merge(defaultConfig, config)

		local requests = {}
		local frame
		local step = flow:createStep({
			onEnter = function()
				frame = ui:createFrame(Color.White)

				local title = ui:createText(str:upperFirstChar(loc("magic key", "title")) .. " 🔑", Color.Black)
				title:setParent(frame)

				local loadingLabel = ui:createText(str:upperFirstChar(loc("loading...")), Color.Black)
				loadingLabel:setParent(frame)
				loadingLabel:hide()

				local magicKeyLabelText = "✉️ What code did you get?"
				local magicKeyLabel = ui:createText(magicKeyLabelText, Color.Black, "default")
				magicKeyLabel:setParent(frame)

				local magicKeyInput =
					ui:createTextInput("", str:upperFirstChar(loc("000000")), { textSize = "default" })
				magicKeyInput:setParent(frame)

				local magicKeyButton = ui:createButton(" ✅ ")
				magicKeyButton:setParent(frame)

				local function showLoading()
					loadingLabel:show()
					magicKeyLabel:hide()
					magicKeyInput:hide()
					magicKeyButton:hide()
				end

				local function hideLoading()
					loadingLabel:hide()
					magicKeyLabel:show()
					magicKeyInput:show()
					magicKeyButton:show()
				end

				magicKeyButton.onRelease = function()
					showLoading()
					local req = api:login(
						{ usernameOrEmail = config.usernameOrEmail, magickey = magicKeyInput.Text },
						function(err, credentials)
							-- res.username, res.password, res.magickey
							if err == nil then
								System:StoreCredentials(credentials["user-id"], credentials.token)
								flowConfig.loginSuccess()
							else
								magicKeyLabel.Text = "❌ " .. err
								hideLoading()
							end
						end
					)
					table.insert(requests, req)
				end

				frame.parentDidResize = function(self)
					self.Width = math.min(
						400,
						Screen.Width - Screen.SafeArea.Right - Screen.SafeArea.Left - theme.paddingBig * 2
					)
					self.Height = title.Height
						+ theme.padding
						+ magicKeyLabel.Height
						+ theme.paddingTiny
						+ magicKeyInput.Height
						+ theme.paddingBig * 2

					title.pos = {
						self.Width * 0.5 - title.Width * 0.5,
						self.Height - theme.paddingBig - title.Height,
					}

					magicKeyButton.Height = magicKeyInput.Height

					magicKeyLabel.pos.X = theme.paddingBig
					magicKeyLabel.pos.Y = title.pos.Y - theme.padding - magicKeyLabel.Height

					magicKeyInput.Width = self.Width - theme.paddingBig * 2 - magicKeyButton.Width - theme.paddingTiny
					magicKeyInput.pos.X = theme.paddingBig
					magicKeyInput.pos.Y = magicKeyLabel.pos.Y - theme.paddingTiny - magicKeyInput.Height

					magicKeyButton.pos.X = magicKeyInput.pos.X + magicKeyInput.Width + theme.paddingTiny
					magicKeyButton.pos.Y = magicKeyInput.pos.Y

					loadingLabel.pos = {
						self.Width * 0.5 - loadingLabel.Width * 0.5,
						self.Height * 0.5 - loadingLabel.Height * 0.5,
					}
					self.pos = { Screen.Width * 0.5 - self.Width * 0.5, Screen.Height * 0.5 - self.Height * 0.5 }
				end
				frame:parentDidResize()
				targetPos = frame.pos:Copy()
				frame.pos.Y = frame.pos.Y - 50
				ease:outBack(frame, animationTime).pos = targetPos
			end,
			onExit = function()
				for _, req in ipairs(requests) do
					req:Cancel()
				end
			end,
			onRemove = function() end,
		})
		return step
	end

	local createLoginOptionsStep = function(config)
		local defaultConfig = {
			username = "",
			password = false,
			magickey = false,
		}
		config = conf:merge(defaultConfig, config)

		local requests = {}
		local frame
		local step = flow:createStep({
			onEnter = function()
				frame = ui:createFrame(Color.White)

				local title = ui:createText(str:upperFirstChar(loc("authentication", "title")) .. " 🔑", Color.Black)
				title:setParent(frame)

				local errorLabel = ui:createText("", Color.Black)
				errorLabel:setParent(frame)
				errorLabel:hide()

				local loadingLabel = ui:createText(str:upperFirstChar(loc("loading...")), Color.Black)
				loadingLabel:setParent(frame)
				loadingLabel:hide()

				local passwordLabel
				local passwordInput
				local passwordButton
				local magicKeyLabel
				local magicKeyButton

				local function showLoading()
					loadingLabel:show()
					if config.password then
						passwordLabel:hide()
						passwordInput:hide()
						passwordButton:hide()
					end
					if config.magickey then
						magicKeyLabel:hide()
						magicKeyButton:hide()
					end
				end

				local function hideLoading()
					loadingLabel:hide()
					if config.password then
						passwordLabel:show()
						passwordInput:show()
						passwordButton:show()
					end
					if config.magickey then
						magicKeyLabel:show()
						magicKeyButton:show()
					end
				end

				if config.password then
					passwordLabel = ui:createText("🔑 " .. str:upperFirstChar(loc("password")), Color.Black, "small")
					passwordLabel:setParent(frame)

					passwordInput = ui:createTextInput(
						"",
						str:upperFirstChar(loc("password")),
						{ textSize = "default", password = true }
					)
					passwordInput:setParent(frame)

					passwordButton = ui:createButton(" ✅ ")
					passwordButton:setParent(frame)
				end

				if config.magickey then
					magicKeyLabel =
						ui:createText(config.password and "or, send me a:" or "send me a:", Color.Black, "default")
					magicKeyLabel:setParent(frame)

					magicKeyButton = ui:createButton(str:upperFirstChar(loc("✨ magic key ✨")))
					magicKeyButton:setColor(Color(0, 161, 169), Color.White)
					magicKeyButton:setParent(frame)

					magicKeyButton.onRelease = function()
						showLoading()
						local req = api:getMagicKey(config.username, function(err, res)
							-- res.username, res.password, res.magickey
							if err == nil then
								System:SetAskedForMagicKey()
								local step = createMagicKeyInputStep({ usernameOrEmail = config.username })
								signupFlow:push(step)
							else
								errorLabel.Text = "❌ sorry, magic key failed to be sent"
								hideLoading()
							end
						end)
						table.insert(requests, req)
					end
				end

				frame.parentDidResize = function(self)
					self.Width = math.min(
						400,
						Screen.Width - Screen.SafeArea.Right - Screen.SafeArea.Left - theme.paddingBig * 2
					)
					self.Height = title.Height + theme.paddingBig * 2

					if config.password then
						self.Height = self.Height + passwordLabel.Height + theme.paddingTiny + passwordInput.Height
					end
					if config.magickey then
						self.Height = self.Height + magicKeyLabel.Height + theme.paddingTiny + magicKeyButton.Height
					end
					if config.password and config.magickey then
						self.Height = self.Height + theme.padding
					end

					title.pos = {
						self.Width * 0.5 - title.Width * 0.5,
						self.Height - theme.paddingBig - title.Height,
					}

					local y = title.pos.Y

					if config.password then
						passwordButton.Height = passwordInput.Height

						passwordLabel.pos.Y = y - passwordLabel.Height
						passwordLabel.pos.X = theme.paddingBig

						passwordInput.Width = self.Width
							- passwordButton.Width
							- theme.paddingTiny
							- theme.paddingBig * 2

						passwordInput.pos.X = theme.paddingBig
						passwordInput.pos.Y = passwordLabel.pos.Y - theme.paddingTiny - passwordInput.Height

						passwordButton.pos.X = passwordInput.pos.X + passwordInput.Width + theme.paddingTiny
						passwordButton.pos.Y = passwordInput.pos.Y

						y = passwordButton.pos.Y - theme.paddingTiny
					end

					if config.magickey then
						magicKeyLabel.pos.X = self.Width * 0.5 - magicKeyLabel.Width * 0.5
						magicKeyLabel.pos.Y = y - magicKeyLabel.Height

						magicKeyButton.Width = self.Width - theme.paddingBig * 2
						magicKeyButton.pos.X = theme.paddingBig
						magicKeyButton.pos.Y = magicKeyLabel.pos.Y - theme.paddingTiny - magicKeyButton.Height
					end

					loadingLabel.pos = {
						self.Width * 0.5 - loadingLabel.Width * 0.5,
						self.Height * 0.5 - loadingLabel.Height * 0.5,
					}
					self.pos = { Screen.Width * 0.5 - self.Width * 0.5, Screen.Height * 0.5 - self.Height * 0.5 }
				end
				frame:parentDidResize()
				targetPos = frame.pos:Copy()
				frame.pos.Y = frame.pos.Y - 50
				ease:outBack(frame, animationTime).pos = targetPos
			end,
			onExit = function()
				for _, req in ipairs(requests) do
					req:Cancel()
				end
				frame:remove()
				frame = nil
			end,
			onRemove = function() end,
		})

		return step
	end

	local createLoginStep = function()
		local requests = {}
		local frame

		local step = flow:createStep({
			onEnter = function()
				config.loginStep()

				-- BACK BUTTON
				showBackButton()

				frame = ui:createFrame(Color.White)

				local title = ui:createText(str:upperFirstChar(loc("who are you?")) .. " 🙂", Color.Black)
				title:setParent(frame)

				local errorLabel = ui:createText("", Color.Black)
				errorLabel:setParent(frame)
				errorLabel:hide()

				local loadingLabel = ui:createText(str:upperFirstChar(loc("loading...")), Color.Black)
				loadingLabel:setParent(frame)
				loadingLabel:hide()

				local usernameInput = ui:createTextInput("", str:upperFirstChar(loc("username or email")))
				usernameInput:setParent(frame)

				local didStartTyping = false
				usernameInput.onTextChange = function(self)
					local backup = self.onTextChange
					self.onTextChange = nil

					local s = str:normalize(self.Text)
					s = str:lower(s)

					self.Text = s
					self.onTextChange = backup

					if didStartTyping == false and self.Text ~= "" then
						didStartTyping = true
						System:DebugEvent("LOGIN_STARTED_TYPING_USERNAME")
					end
				end

				local loginButton = ui:createButton(" ✨ " .. str:upperFirstChar(loc("login", "button")) .. " ✨ ") -- , { textSize = "big" })
				loginButton:setParent(frame)
				loginButton:setColor(Color(150, 200, 61), Color(240, 255, 240))

				frame.parentDidResize = function(self)
					self.Height = title.Height
						+ usernameInput.Height
						+ loginButton.Height
						+ theme.padding * 2
						+ theme.paddingBig * 2

					if errorLabel.Text ~= "" then
						self.Height = self.Height + errorLabel.Height + theme.padding
					end

					self.Width = math.min(
						400,
						Screen.Width - Screen.SafeArea.Right - Screen.SafeArea.Left - theme.paddingBig * 2
					)

					title.pos = {
						self.Width * 0.5 - title.Width * 0.5,
						self.Height - theme.paddingBig - title.Height,
					}

					local y = title.pos.Y
					if errorLabel.Text ~= "" then
						errorLabel:show()
						errorLabel.pos = {
							theme.paddingBig,
							y - theme.padding - errorLabel.Height,
						}
						y = errorLabel.pos.Y
					else
						errorLabel:hide()
					end

					usernameInput.Width = self.Width - theme.paddingBig * 2
					usernameInput.pos = {
						theme.paddingBig,
						y - theme.padding - usernameInput.Height,
					}

					loginButton.Width = self.Width - theme.paddingBig * 2
					loginButton.pos = { theme.paddingBig, theme.paddingBig }

					loadingLabel.pos = {
						self.Width * 0.5 - loadingLabel.Width * 0.5,
						self.Height * 0.5 - loadingLabel.Height * 0.5,
					}

					self.pos = { Screen.Width * 0.5 - self.Width * 0.5, Screen.Height * 0.5 - self.Height * 0.5 }
				end
				frame:parentDidResize()
				targetPos = frame.pos:Copy()
				frame.pos.Y = frame.pos.Y - 50
				ease:outBack(frame, animationTime).pos = targetPos

				local function showLoading()
					loadingLabel:show()
					usernameInput:hide()
					loginButton:hide()
				end

				local function hideLoading()
					loadingLabel:hide()
					usernameInput:show()
					loginButton:show()
					frame:parentDidResize()
				end

				loginButton.onRelease = function()
					-- save in case user comes back with magic key after closing app
					System:SaveUsernameOrEmail(usernameInput.Text)
					-- if user asked for magic key in the past, this is the best
					-- time to forget about it.
					System:RemoveAskedForMagicKey()

					errorLabel.Text = ""
					showLoading()
					local req = api:getLoginOptions(usernameInput.Text, function(err, res)
						-- res.username, res.password, res.magickey
						if err == nil then
							-- NOTE: res.username is sanitized
							local step = createLoginOptionsStep({
								username = res.username,
								password = res.password,
								magickey = res.magickey,
							})
							signupFlow:push(step)
						else
							errorLabel.Text = "❌ " .. err
							hideLoading()
						end
					end)
					table.insert(requests, req)
				end
			end, -- onEnter
			onExit = function()
				for _, req in ipairs(requests) do
					req:Cancel()
				end
				frame:remove()
				frame = nil
			end,
			onRemove = function()
				removeBackButton()
			end,
		})
		return step
	end

	local createPhoneNumberStep = function()
		local step = flow:createStep({
			onEnter = function()
				config.phoneNumberStep()

				showBackButton()
				showCoinsButton()

				-- DRAWER
				if drawer ~= nil then
					drawer:clear()
				else
					drawer = drawerModule:create({ ui = ui })
				end

				local okBtn = ui:createButton("Confirm", { textSize = "big" })
				okBtn:setColor(theme.colorPositive)
				okBtn:setParent(drawer)
				okBtn.onRelease = function()
					-- signupFlow:push(createAvatarEditorStep())
					api:patchUserPhone({ phone = "+33768201427" }, function(err)
						if err ~= nil then
							print("ERR:", err)
						end
					end)
				end
				-- okBtn:disable()

				local text = ui:createText("Final step! What's your phone number?", {
					color = Color.Black,
				})
				text:setParent(drawer)

				local proposedCountries = {
					"US",
					"CA",
					"GB",
					"DE",
					"FR",
					"IT",
					"ES",
					"NL",
					"RU",
					"CN",
					"IN",
					"JP",
					"KR",
					"AU",
					"BR",
					"MX",
					"AR",
					"ZA",
					"SA",
					"TR",
					"ID",
					"VN",
					"TH",
					"MY",
					"PH",
					"SG",
					"AE",
					"IL",
					"UA",
				}
				-- local countries = phonenumbers.countries
				local countryLabels = {}
				local c
				for _, countryCode in ipairs(proposedCountries) do
					c = phonenumbers.countryCodes[countryCode]
					if c ~= nil then
						table.insert(countryLabels, c.code .. " +" .. c.prefix)
					end
				end
				-- for _, country in ipairs(countries) do
				-- 	table.insert(countryLabels, country.code .. " +" .. country.prefix)
				-- end

				local countryInput = ui:createComboBox("US +1", countryLabels)
				countryInput:setParent(drawer)

				local phoneInput = ui:createTextInput(
					"",
					str:upperFirstChar(loc("phone number")),
					{ textSize = "big", keyboardType = "phone", suggestions = false }
				)
				phoneInput:setParent(drawer)

				local layoutPhoneInput = function()
					phoneInput.Width = drawer.Width - theme.paddingBig * 2 - countryInput.Width - theme.padding
					phoneInput.pos = {
						countryInput.pos.X + countryInput.Width + theme.padding,
						countryInput.pos.Y,
					}
				end

				countryInput.onSelect = function(self, index)
					System:DebugEvent("User did pick country for phone number")
					self.Text = countryLabels[index]
					layoutPhoneInput()
				end

				phoneInput.onTextChange = function(self)
					local backup = self.onTextChange
					self.onTextChange = nil

					local res = phonenumbers:extractCountryCode(self.Text)
					if res.countryCode ~= nil then
						self.Text = res.remainingNumber
						countryInput.Text = res.countryCode .. " +" .. res.countryPrefix
						layoutPhoneInput()
					end

					self.onTextChange = backup
				end

				local secondaryText = ui:createText(
					"Cubzh asks for phone numbers to secure accounts and fight against cheaters. Information kept private. 🔑",
					{
						color = Color(100, 100, 100),
						size = "small",
					}
				)
				secondaryText:setParent(drawer)

				drawer:updateConfig({
					layoutContent = function(self)
						-- here, self.Height can be reduced, but not increased
						-- TODO: enforce this within drawer module

						local padding = theme.paddingBig
						local smallPadding = theme.padding

						local maxWidth = math.min(300, self.Width - padding * 2)
						text.object.MaxWidth = maxWidth
						secondaryText.object.MaxWidth = maxWidth

						local w = math.min(self.Width, math.max(text.Width, okBtn.Width, 300) + padding * 2)

						local availableWidth = w - padding * 2
						countryInput.Height = phoneInput.Height
						phoneInput.Width = availableWidth - countryInput.Width - smallPadding

						self.Width = w
						self.Height = Screen.SafeArea.Bottom
							+ okBtn.Height
							+ text.Height
							+ secondaryText.Height
							+ phoneInput.Height
							+ padding * 5

						okBtn.pos = { self.Width * 0.5 - okBtn.Width * 0.5, Screen.SafeArea.Bottom + padding }
						secondaryText.pos = {
							self.Width * 0.5 - secondaryText.Width * 0.5,
							okBtn.pos.Y + okBtn.Height + padding,
						}
						countryInput.pos = {
							padding,
							secondaryText.pos.Y + secondaryText.Height + padding,
						}
						phoneInput.pos = {
							countryInput.pos.X + countryInput.Width + smallPadding,
							countryInput.pos.Y,
						}
						text.pos = {
							self.Width * 0.5 - text.Width * 0.5,
							countryInput.pos.Y + countryInput.Height + padding,
						}

						LocalEvent:Send("signup_drawer_height_update", self.Height)
					end,
				})

				drawer:show()
			end,
			onExit = function() end,
			onRemove = function() end,
		})

		return step
	end

	local createDOBStep = function()
		local step = flow:createStep({
			onEnter = function()
				config.dobStep()

				showBackButton()
				showCoinsButton()

				-- DRAWER
				if drawer ~= nil then
					drawer:clear()
				else
					drawer = drawerModule:create({ ui = ui })
				end

				local okBtn = ui:createButton("Confirm", { textSize = "big" })
				okBtn:setColor(theme.colorPositive)
				okBtn:setParent(drawer)
				okBtn.onRelease = function()
					signupFlow:push(createPhoneNumberStep())
				end
				okBtn:disable()

				local text = ui:createText("Looking good! Now, what's your date of birth, in real life? 🎂", {
					color = Color.Black,
				})
				text:setParent(drawer)

				local secondaryText = ui:createText(
					"Cubzh is an online social universe. We have to ask this to protect the young ones and will keep that information private. 🔑",
					{
						color = Color(100, 100, 100),
						size = "small",
					}
				)
				secondaryText:setParent(drawer)

				local _year
				local _month
				local _day

				local monthNames = {
					str:upperFirstChar(loc("january")),
					str:upperFirstChar(loc("february")),
					str:upperFirstChar(loc("march")),
					str:upperFirstChar(loc("april")),
					str:upperFirstChar(loc("may")),
					str:upperFirstChar(loc("june")),
					str:upperFirstChar(loc("july")),
					str:upperFirstChar(loc("august")),
					str:upperFirstChar(loc("september")),
					str:upperFirstChar(loc("october")),
					str:upperFirstChar(loc("november")),
					str:upperFirstChar(loc("december")),
				}
				local dayNumbers = {}
				for i = 1, 31 do
					table.insert(dayNumbers, "" .. i)
				end

				local years = {}
				local yearStrings = {}
				local currentYear = math.floor(tonumber(os.date("%Y")))
				local currentMonth = math.floor(tonumber(os.date("%m")))
				local currentDay = math.floor(tonumber(os.date("%d")))

				for i = currentYear, currentYear - 100, -1 do
					table.insert(years, i)
					table.insert(yearStrings, "" .. i)
				end

				local function isLeapYear(year)
					if year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then
						return true
					else
						return false
					end
				end

				local function nbDays(m)
					if m == 2 then
						if isLeapYear(m) then
							return 29
						else
							return 28
						end
					else
						local days = { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
						return days[m]
					end
				end

				local monthInput = ui:createComboBox(str:upperFirstChar(loc("month")), monthNames)
				monthInput:setParent(drawer)

				local dayInput = ui:createComboBox(str:upperFirstChar(loc("day")), dayNumbers)
				dayInput:setParent(drawer)

				local yearInput = ui:createComboBox(str:upperFirstChar(loc("year")), yearStrings)
				yearInput:setParent(drawer)

				local checkDOB = function()
					local r = true
					local daysInMonth = nbDays(_month)

					if _year == nil or _month == nil or _day == nil then
						-- if config and config.errorIfIncomplete == true then
						-- birthdayInfo.Text = "❌ " .. loc("required")
						-- birthdayInfo.Color = theme.errorTextColor
						r = false
						-- else
						-- 	birthdayInfo.Text = ""
						-- end
					elseif _day < 0 or _day > daysInMonth then
						-- birthdayInfo.Text = "❌ invalid date"
						-- birthdayInfo.Color = theme.errorTextColor
						r = false
					elseif
						_year > currentYear
						or (_year == currentYear and _month > currentMonth)
						or (_year == currentYear and _month == currentMonth and _day > currentDay)
					then
						-- birthdayInfo.Text = "❌ users from the future not allowed"
						-- birthdayInfo.Color = theme.errorTextColor
						r = false
						-- else
						-- 	birthdayInfo.Text = ""
					end

					-- birthdayInfo.pos.X = node.Width - birthdayInfo.Width
					return r
				end

				monthInput.onSelect = function(self, index)
					System:DebugEvent("SIGNUP_PICK_MONTH")
					_month = index
					self.Text = monthNames[index]
					if checkDOB() then
						okBtn:enable()
					end
				end

				dayInput.onSelect = function(self, index)
					System:DebugEvent("SIGNUP_PICK_DAY")
					_day = index
					self.Text = dayNumbers[index]
					if checkDOB() then
						okBtn:enable()
					end
				end

				yearInput.onSelect = function(self, index)
					System:DebugEvent("SIGNUP_PICK_YEAR")
					_year = years[index]
					self.Text = yearStrings[index]
					if checkDOB() then
						okBtn:enable()
					end
				end

				drawer:updateConfig({
					layoutContent = function(self)
						-- here, self.Height can be reduced, but not increased
						-- TODO: enforce this within drawer module

						local padding = theme.paddingBig
						local smallPadding = theme.padding

						local maxWidth = math.min(300, self.Width - padding * 2)
						text.object.MaxWidth = maxWidth
						secondaryText.object.MaxWidth = maxWidth

						local w = math.min(self.Width, math.max(text.Width, okBtn.Width, 300) + padding * 2)

						local availableWidthForInputs = w - padding * 2 - smallPadding * 2

						monthInput.Width = availableWidthForInputs * 0.5
						dayInput.Width = availableWidthForInputs * 0.2
						yearInput.Width = availableWidthForInputs * 0.3

						self.Width = w
						self.Height = Screen.SafeArea.Bottom
							+ okBtn.Height
							+ monthInput.Height
							+ text.Height
							+ secondaryText.Height
							+ padding * 5

						okBtn.pos = { self.Width * 0.5 - okBtn.Width * 0.5, Screen.SafeArea.Bottom + padding }
						secondaryText.pos = {
							self.Width * 0.5 - secondaryText.Width * 0.5,
							okBtn.pos.Y + okBtn.Height + padding,
						}
						monthInput.pos = {
							padding,
							secondaryText.pos.Y + secondaryText.Height + padding,
						}
						dayInput.pos = {
							monthInput.pos.X + monthInput.Width + smallPadding,
							secondaryText.pos.Y + secondaryText.Height + padding,
						}
						yearInput.pos = {
							dayInput.pos.X + dayInput.Width + smallPadding,
							secondaryText.pos.Y + secondaryText.Height + padding,
						}
						text.pos =
							{ self.Width * 0.5 - text.Width * 0.5, monthInput.pos.Y + monthInput.Height + padding }

						LocalEvent:Send("signup_drawer_height_update", self.Height)
					end,
				})

				drawer:show()
			end,
			onExit = function() end,
			onRemove = function() end,
		})

		return step
	end

	local createAvatarEditorStep = function()
		local avatarEditor
		local okBtn
		local infoFrame
		local info
		local avatarUpdateListener
		local nbPartsChanged = 0
		local nbPartsToChange = 3
		local partsChanged = {}

		local step = flow:createStep({
			onEnter = function()
				config.avatarEditorStep()

				showBackButton()
				showCoinsButton()

				infoFrame = ui:createFrame(Color(0, 0, 0, 0.3))
				info = ui:createText(string.format("Change at least %d things to continue!", nbPartsToChange), {
					color = Color.White,
				})
				info:setParent(infoFrame)
				info.pos = { padding, padding }

				okBtn = ui:buttonPositive({ content = "Done!", textSize = "big" })
				-- okBtn = ui:createButton(" Done! ", { textSize = "big" })
				-- okBtn:setColor(theme.colorPositive)
				okBtn.onRelease = function(self)
					-- go to next step
					signupFlow:push(createDOBStep())
				end
				okBtn:disable()

				local function layoutInfoFrame()
					local parent = infoFrame.parent
					if not parent then
						return
					end
					info.object.MaxWidth = parent.Width - okBtn.Width - padding * 5
					infoFrame.Width = info.Width + padding * 2
					infoFrame.Height = info.Height + padding * 2
					infoFrame.pos = {
						okBtn.pos.X - infoFrame.Width - padding,
						infoFrame.Height > okBtn.Height and okBtn.pos.Y
							or okBtn.pos.Y + okBtn.Height * 0.5 - infoFrame.Height * 0.5,
					}
				end

				avatarUpdateListener = LocalEvent:Listen("avatar_editor_update", function(config)
					if config.skinColorIndex then
						if not partsChanged["skin"] then
							nbPartsChanged = nbPartsChanged + 1
							partsChanged["skin"] = true
						end
					end
					if config.eyesIndex then
						if not partsChanged["eyes"] then
							nbPartsChanged = nbPartsChanged + 1
							partsChanged["eyes"] = true
						end
					end
					if config.noseIndex then
						if not partsChanged["nose"] then
							nbPartsChanged = nbPartsChanged + 1
							partsChanged["nose"] = true
						end
					end
					if config.jacket then
						if not partsChanged["jacket"] then
							nbPartsChanged = nbPartsChanged + 1
							partsChanged["jacket"] = true
						end
					end
					if config.hair then
						if not partsChanged["hair"] then
							nbPartsChanged = nbPartsChanged + 1
							partsChanged["hair"] = true
						end
					end
					if config.pants then
						if not partsChanged["pants"] then
							nbPartsChanged = nbPartsChanged + 1
							partsChanged["pants"] = true
						end
					end
					if config.boots then
						if not partsChanged["boots"] then
							nbPartsChanged = nbPartsChanged + 1
							partsChanged["boots"] = true
						end
					end

					local remaining = math.max(0, nbPartsToChange - nbPartsChanged)
					if remaining == 0 then
						info.text = "You're good to go!"
						okBtn:enable()
					else
						info.text = string.format("Change %d more things to continue!", remaining)
					end
					layoutInfoFrame()
				end)

				-- DRAWER
				if drawer ~= nil then
					drawer:clear()
				else
					drawer = drawerModule:create({ ui = ui })
				end

				okBtn:setParent(drawer)
				infoFrame:setParent(drawer)

				avatarEditor = require("ui_avatar_editor"):create({
					ui = ui,
					requestHeightCallback = function(height)
						drawer:updateConfig({
							layoutContent = function(self)
								local drawerHeight = height + padding * 2 + Screen.SafeArea.Bottom
								drawerHeight = math.min(Screen.Height * 0.6, drawerHeight)

								self.Height = drawerHeight

								if avatarEditor then
									avatarEditor.Width = self.Width - padding * 2
									avatarEditor.Height = drawerHeight - Screen.SafeArea.Bottom - padding * 2
									avatarEditor.pos = { padding, Screen.SafeArea.Bottom + padding }
								end

								okBtn.pos = {
									self.Width - okBtn.Width - padding,
									self.Height + padding,
								}

								layoutInfoFrame()

								LocalEvent:Send("signup_drawer_height_update", drawerHeight)
							end,
						})
						drawer:bump()
					end,
				})

				avatarEditor:setParent(drawer)

				drawer:updateConfig({
					layoutContent = function(self)
						avatarEditor.Width = self.Width - padding * 2
						avatarEditor.Height = self.Height - padding * 2 - Screen.SafeArea.Bottom

						avatarEditor.pos = { padding, Screen.SafeArea.Bottom + padding }

						okBtn.pos = {
							drawer.Width - okBtn.Width - padding,
							drawer.Height + padding,
						}

						LocalEvent:Send("signup_drawer_height_update", self.Height)
					end,
				})

				drawer:show()
			end,
			onExit = function()
				drawer:hide()
				okBtn:remove()
				if avatarUpdateListener then
					avatarUpdateListener:Remove()
				end
			end,
			onRemove = function() end,
		})

		return step
	end

	local createAvatarPreviewStep = function()
		local step = flow:createStep({
			onEnter = function()
				config.avatarPreviewStep()

				showBackButton()
				removeCoinsButton()

				-- DRAWER
				if drawer ~= nil then
					drawer:clear()
				else
					drawer = drawerModule:create({ ui = ui })
				end

				local okBtn = ui:buttonPositive({ content = "Ok, let's do this!", textSize = "big" })
				-- local okBtn = ui:createButton("Ok, let's do this!", { textSize = "big" })
				-- okBtn:setColor(theme.colorPositive)
				okBtn:setParent(drawer)
				okBtn.onRelease = function()
					signupFlow:push(createAvatarEditorStep())
				end

				local text = ui:createText("You need an AVATAR to visit Cubzh worlds! Let's create one now ok? 🙂", {
					color = Color.Black,
				})
				text:setParent(drawer)

				drawer:updateConfig({
					layoutContent = function(self)
						-- here, self.Height can be reduced, but not increased
						-- TODO: enforce this within drawer module

						text.object.MaxWidth = math.min(300, self.Width - theme.paddingBig * 2)

						self.Width = math.min(self.Width, math.max(text.Width, okBtn.Width) + theme.paddingBig * 2)
						self.Height = Screen.SafeArea.Bottom + okBtn.Height + text.Height + theme.paddingBig * 3

						okBtn.pos = { self.Width * 0.5 - okBtn.Width * 0.5, Screen.SafeArea.Bottom + theme.paddingBig }
						text.pos =
							{ self.Width * 0.5 - text.Width * 0.5, okBtn.pos.Y + okBtn.Height + theme.paddingBig }

						LocalEvent:Send("signup_drawer_height_update", self.Height)
					end,
				})

				drawer:show()
			end,
			-- exit = function(continue)
			-- 	-- TODO
			-- 	continue()
			-- end,
			onExit = function()
				drawer:hide()
			end,
			onRemove = function()
				removeBackButton()
				drawer:remove()
				drawer = nil
				config.onCancel() -- TODO: can't stay here (step also removed when completing flow)
			end,
		})

		return step
	end

	local createSignUpOrLoginStep = function()
		local startBtn
		local step = flow:createStep({
			onEnter = function()
				config.signUpOrLoginStep()

				if loginBtn == nil then
					loginBtn = ui:buttonSecondary({ content = "Login", textSize = "small" })
					-- loginBtn = ui:createButton("Login", { textSize = "small", borders = false })
					-- loginBtn:setColor(Color(0, 0, 0, 0.4), Color(255, 255, 255))
					loginBtn.parentDidResize = function(self)
						ease:cancel(self)
						self.pos = {
							Screen.Width - Screen.SafeArea.Right - self.Width - padding,
							Screen.Height - Screen.SafeArea.Top - self.Height - padding,
						}
					end

					loginBtn.onRelease = function()
						signupFlow:push(createLoginStep())
					end
				end
				loginBtn:parentDidResize()
				local targetPos = loginBtn.pos:Copy()
				loginBtn.pos.X = Screen.Width
				ease:outSine(loginBtn, animationTime).pos = targetPos

				startBtn = ui:buttonPositive({ content = "Start", textSize = "big" })
				-- startBtn:setColor(theme.colorPositive)
				startBtn.parentDidResize = function(self)
					ease:cancel(self)
					self.Width = 100
					self.Height = 50
					self.pos = {
						Screen.Width * 0.5 - self.Width * 0.5,
						Screen.Height / 5.0 - self.Height * 0.5,
					}
				end
				startBtn:parentDidResize()
				targetPos = startBtn.pos:Copy()
				startBtn.pos.Y = startBtn.pos.Y - 50
				ease:outBack(startBtn, animationTime).pos = targetPos

				startBtn.onRelease = function()
					signupFlow:push(createAvatarPreviewStep())
				end
			end,
			onExit = function()
				startBtn:remove()
				startBtn = nil
				loginBtn:remove()
				loginBtn = nil
			end,
			onRemove = function() end,
		})
		return step
	end

	local createCheckAppVersionAndCredentialsStep = function()
		local loadingFrame
		local step = flow:createStep({
			onEnter = function()
				if loadingFrame == nil then
					loadingFrame = ui:createFrame(Color(0, 0, 0, 0.3))

					local text =
						ui:createText("You need an AVATAR to visit Cubzh worlds! Let's create one now ok? 🙂", {
							color = Color.White,
						})
					text:setParent(loadingFrame)
					text.pos = { theme.paddingBig, theme.paddingBig }

					loadingFrame.parentDidResize = function(self)
						ease:cancel(self)

						loadingFrame.Width = text.Width + theme.paddingBig * 2
						loadingFrame.Height = text.Height + theme.paddingBig * 2

						self.pos = {
							Screen.Width * 0.5 - self.Width * 0.5,
							Screen.Height / 5.0 - self.Height * 0.5,
						}
					end
					loadingFrame:parentDidResize()

					local function parseVersion(versionStr)
						local maj, min, patch = versionStr:match("(%d+)%.(%d+)%.(%d+)")
						maj = math.floor(tonumber(maj))
						min = math.floor(tonumber(min))
						patch = math.floor(tonumber(patch))
						return maj, min, patch
					end

					text.Text = "Checking app version..."
					loadingFrame:parentDidResize()

					local checks = {}

					checks.minAppVersion = function()
						api:getMinAppVersion(function(error, minVersion)
							if error ~= nil then
								-- TODO: show button to retry + error
								-- if callbacks.networkError then
								-- 	callbacks.networkError()
								-- end
								return
							end

							local major, minor, patch = parseVersion(Client.AppVersion)
							local minMajor, minMinor, minPatch = parseVersion(minVersion)

							-- minPatch = 51 -- force trigger, for tests
							if
								major < minMajor
								or (major == minMajor and minor < minMinor)
								or (minor == minMinor and patch < minPatch)
							then
								if callbacks.updateRequired then
									local minVersion = string.format("%d.%d.%d", minMajor, minMinor, minPatch)
									local currentVersion = string.format("%d.%d.%d", major, minor, patch)
									-- callbacks.updateRequired(minVersion, currentVersion)
								end

								text.Text = "⚠️ App needs to be updated!\nminimum version: "
									.. string.format("%d.%d.%d", minMajor, minMinor, minPatch)
									.. "\n"
									.. "installed: "
									.. string.format("%d.%d.%d", major, minor, patch)
								loadingFrame:parentDidResize()
							else
								checks.magicKey()
							end
						end)
					end

					checks.magicKey = function()
						text.Text = "Checking magic key..."
						loadingFrame:parentDidResize()

						if System.HasCredentials == false and System.AskedForMagicKey then
							System:RemoveAskedForMagicKey()

							-- TODO: show magic key prompt

							-- authFlow:showLogin(callbacks)
							-- if callbacks.requestedMagicKey ~= nil then
							-- 	callbacks.requestedMagicKey()
							-- end
						else
							checks.account()
						end
					end

					checks.account = function()
						text.Text = "Checking user info..."
						loadingFrame:parentDidResize()

						if System.HasCredentials == false then
							signupFlow:push(createSignUpOrLoginStep())
							return
						end

						-- Fetch account info
						-- it's ok to continue if err == nil
						-- (info updated at the engine level)
						System.GetAccountInfo(function(err, res)
							if err ~= nil then
								-- TODO: show button to retry + error
								-- if callbacks.error then
								-- 	callbacks.error()
								-- end
								return
							end

							local accountInfo = res

							if accountInfo.hasDOB == false or accountInfo.hasUsername == false then
								-- TODO: show info about anonymous accounts
								-- if callbacks.accountIncomplete then
								-- 	callbacks.accountIncomplete()
								-- end
								return
							end

							if System.Under13DisclaimerNeedsApproval then
								if callbacks.under13DisclaimerNeedsApproval then
									-- TODO: push under 13 disclaimer
									-- callbacks.under13DisclaimerNeedsApproval()
									return
								end
							end

							-- NOTE: accountInfo.hasPassword could be false here
							-- for some accounts created pre-0.0.52.
							-- (mandatory after that)

							config.loginSuccess()
						end)
					end

					checks.minAppVersion()
				end
				loadingFrame:parentDidResize()
			end,
			onExit = function()
				loadingFrame:remove()
				loadingFrame = nil
			end,
			onRemove = function() end,
		})
		return step
	end

	signupFlow:push(createCheckAppVersionAndCredentialsStep())

	return signupFlow
end

-- signup.createModal = function(_, config)
-- 	local loc = require("localize")
-- 	local str = require("str")
-- 	local ui = require("uikit")
-- 	local modal = require("modal")
-- 	local theme = require("uitheme").current
-- 	local ease = require("ease")
-- 	local api = require("system_api", System)
-- 	local conf = require("config")

-- 	local defaultConfig = {
-- 		uikit = ui,
-- 	}

-- 	config = conf:merge(defaultConfig, config)

-- 	ui = config.uikit

-- 	local _year
-- 	local _month
-- 	local _day

-- 	local monthNames = {
-- 		str:upperFirstChar(loc("january")),
-- 		str:upperFirstChar(loc("february")),
-- 		str:upperFirstChar(loc("march")),
-- 		str:upperFirstChar(loc("april")),
-- 		str:upperFirstChar(loc("may")),
-- 		str:upperFirstChar(loc("june")),
-- 		str:upperFirstChar(loc("july")),
-- 		str:upperFirstChar(loc("august")),
-- 		str:upperFirstChar(loc("september")),
-- 		str:upperFirstChar(loc("october")),
-- 		str:upperFirstChar(loc("november")),
-- 		str:upperFirstChar(loc("december")),
-- 	}
-- 	local dayNumbers = {}
-- 	for i = 1, 31 do
-- 		table.insert(dayNumbers, "" .. i)
-- 	end

-- 	local years = {}
-- 	local yearStrings = {}
-- 	local currentYear = math.floor(tonumber(os.date("%Y")))
-- 	local currentMonth = math.floor(tonumber(os.date("%m")))
-- 	local currentDay = math.floor(tonumber(os.date("%d")))

-- 	for i = currentYear, currentYear - 100, -1 do
-- 		table.insert(years, i)
-- 		table.insert(yearStrings, "" .. i)
-- 	end

-- 	local function isLeapYear(year)
-- 		if year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then
-- 			return true
-- 		else
-- 			return false
-- 		end
-- 	end

-- 	local function nbDays(m)
-- 		if m == 2 then
-- 			if isLeapYear(m) then
-- 				return 29
-- 			else
-- 				return 28
-- 			end
-- 		else
-- 			local days = { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
-- 			return days[m]
-- 		end
-- 	end

-- 	local function idealReducedContentSize(content, _, _)
-- 		if content.refresh then
-- 			content:refresh()
-- 		end

-- 		-- print("-- 1 -", content.Width,content.Height)
-- 		-- Timer(1.0, function() content:refresh() print("-- 2 -", content.Width,content.Height) end)
-- 		return Number2(content.Width, content.Height)
-- 	end

-- 	-- initial content, asking for year of birth
-- 	local content = modal:createContent({ uikit = ui })
-- 	content.idealReducedContentSize = idealReducedContentSize

-- 	local node = ui:createFrame(Color(0, 0, 0, 0))
-- 	content.node = node

-- 	content.title = str:upperFirstChar(loc("sign up", "title"))
-- 	content.icon = "🙂"

-- 	local birthdayLabel =
-- 		ui:createText("🎂 " .. str:upperFirstChar(loc("date of birth")), Color(200, 200, 200, 255), "small")
-- 	birthdayLabel:setParent(node)

-- 	local birthdayInfo = ui:createText("", Color(251, 206, 0, 255), "small")
-- 	birthdayInfo:setParent(node)

-- 	local monthInput = ui:createComboBox(str:upperFirstChar(loc("month")), monthNames)
-- 	monthInput:setParent(node)

-- 	local dayInput = ui:createComboBox(str:upperFirstChar(loc("day")), dayNumbers)
-- 	dayInput:setParent(node)

-- 	local yearInput = ui:createComboBox(str:upperFirstChar(loc("year")), yearStrings)
-- 	yearInput:setParent(node)

-- 	local usernameLabel =
-- 		ui:createText("👤 " .. str:upperFirstChar(loc("username")), Color(200, 200, 200, 255), "small")
-- 	usernameLabel:setParent(node)

-- 	local usernameInfo = ui:createText("⚠️ " .. loc("can't be changed"), Color(251, 206, 0, 255), "small")
-- 	usernameInfo:setParent(node)

-- 	local usernameInput = ui:createTextInput("", str:upperFirstChar(loc("don't use your real name!")))
-- 	usernameInput:setParent(node)

-- 	local usernameInfoFrame = nil
-- 	local usernameInfoDT = nil

-- 	local checkDOB = function(config)
-- 		local r = true
-- 		local daysInMonth = nbDays(_month)

-- 		if _year == nil or _month == nil or _day == nil then
-- 			if config and config.errorIfIncomplete == true then
-- 				birthdayInfo.Text = "❌ " .. loc("required")
-- 				birthdayInfo.Color = theme.errorTextColor
-- 				r = false
-- 			else
-- 				birthdayInfo.Text = ""
-- 			end
-- 		elseif _day < 0 or _day > daysInMonth then
-- 			birthdayInfo.Text = "❌ invalid date"
-- 			birthdayInfo.Color = theme.errorTextColor
-- 			r = false
-- 		elseif
-- 			_year > currentYear
-- 			or (_year == currentYear and _month > currentMonth)
-- 			or (_year == currentYear and _month == currentMonth and _day > currentDay)
-- 		then
-- 			birthdayInfo.Text = "❌ users from the future not allowed"
-- 			birthdayInfo.Color = theme.errorTextColor
-- 			r = false
-- 		else
-- 			birthdayInfo.Text = ""
-- 		end

-- 		birthdayInfo.pos.X = node.Width - birthdayInfo.Width
-- 		return r
-- 	end

-- 	monthInput.onSelect = function(self, index)
-- 		System:DebugEvent("SIGNUP_PICK_MONTH")
-- 		_month = index
-- 		self.Text = monthNames[index]
-- 		checkDOB()
-- 	end

-- 	dayInput.onSelect = function(self, index)
-- 		System:DebugEvent("SIGNUP_PICK_DAY")
-- 		_day = index
-- 		self.Text = dayNumbers[index]
-- 		checkDOB()
-- 	end

-- 	yearInput.onSelect = function(self, index)
-- 		System:DebugEvent("SIGNUP_PICK_YEAR")
-- 		_year = years[index]
-- 		self.Text = yearStrings[index]
-- 		checkDOB()
-- 	end

-- 	local checkUsernameTimer = nil
-- 	local checkUsernameRequest = nil
-- 	local checkUsernameKey = nil
-- 	local checkUsernameError = nil
-- 	local reportWrongFormatTimer = nil

-- 	-- callback(ok, key)
-- 	local checkUsername = function(callback, config)
-- 		if checkUsernameTimer ~= nil then
-- 			checkUsernameTimer:Cancel()
-- 			checkUsernameTimer = nil
-- 		end
-- 		if checkUsernameRequest ~= nil then
-- 			checkUsernameRequest:Cancel()
-- 			checkUsernameRequest = nil
-- 		end

-- 		if checkUsernameError ~= nil then
-- 			if callback then
-- 				callback(false, nil)
-- 			end
-- 			return
-- 		end

-- 		if checkUsernameKey ~= nil then
-- 			if callback then
-- 				callback(true, checkUsernameKey)
-- 			end
-- 			return
-- 		end

-- 		local r = true
-- 		local s = usernameInput.Text

-- 		local usernameInfoDTBackup = usernameInfoDT
-- 		usernameInfoDT = nil

-- 		if s == "" then
-- 			if config and config.errorIfEmpty == true then
-- 				usernameInfo.Text = "❌ " .. loc("required")
-- 				usernameInfo.Color = theme.errorTextColor
-- 			else
-- 				usernameInfo.Text = "⚠️ " .. loc("can't be changed")
-- 				usernameInfo.Color = theme.warningTextColor
-- 			end
-- 			r = false
-- 		elseif not s:match("^[a-z].*$") then
-- 			usernameInfo.Text = "❌ " .. loc("must start with a-z")
-- 			usernameInfo.Color = theme.errorTextColor
-- 			r = false
-- 			if reportWrongFormatTimer == nil then
-- 				System:DebugEvent("SIGNUP_WRONG_FORMAT_USERNAME", { username = s })
-- 				reportWrongFormatTimer = Timer(30, function() -- do not report again within the next 30 sec
-- 					reportWrongFormatTimer = nil
-- 				end)
-- 			end
-- 		elseif #s > 15 then
-- 			usernameInfo.Text = "❌ " .. loc("too long")
-- 			usernameInfo.Color = theme.errorTextColor
-- 			r = false
-- 		elseif not s:match("^[a-z][a-z0-9]*$") then
-- 			usernameInfo.Text = "❌ " .. loc("a-z 0-9 only")
-- 			usernameInfo.Color = theme.errorTextColor
-- 			r = false
-- 			if reportWrongFormatTimer == nil then
-- 				print("REPORT WRONG FORMAT")
-- 				System:DebugEvent("SIGNUP_WRONG_FORMAT_USERNAME", { username = s })
-- 				reportWrongFormatTimer = Timer(30, function() -- do not report again within the next 30 sec
-- 					reportWrongFormatTimer = nil
-- 				end)
-- 			end
-- 		else
-- 			local function displayChecking()
-- 				usernameInfoFrame = 0
-- 				usernameInfoDT = usernameInfoDTBackup or 0
-- 				usernameInfo.Text = loc("checking") .. "   "
-- 				usernameInfo.Color = Color(200, 200, 200, 255)
-- 				usernameInfo.pos.X = node.Width - usernameInfo.Width
-- 			end

-- 			local function request()
-- 				checkUsernameRequest = api:checkUsername(s, function(success, res)
-- 					usernameInfoDT = nil
-- 					checkUsernameRequest = nil

-- 					if success == false then
-- 						usernameInfo.Text = "❌ " .. loc("server error")
-- 						usernameInfo.Color = theme.errorTextColor
-- 					elseif res.format ~= true then
-- 						usernameInfo.Text = "❌ format error"
-- 						usernameInfo.Color = theme.errorTextColor
-- 						checkUsernameError = true
-- 					elseif res.appropriate ~= true then
-- 						usernameInfo.Text = "❌ " .. loc("not appropriate")
-- 						usernameInfo.Color = theme.errorTextColor
-- 						checkUsernameError = true
-- 					elseif res.available ~= true then
-- 						usernameInfo.Text = "❌ " .. loc("already taken")
-- 						usernameInfo.Color = theme.errorTextColor
-- 						checkUsernameError = true
-- 					elseif type(res.key) ~= "string" then
-- 						usernameInfo.Text = "❌ " .. loc("server error")
-- 						usernameInfo.Color = theme.errorTextColor
-- 					else
-- 						System:DebugEvent("SIGNUP_ENTERED_VALID_USERNAME")
-- 						usernameInfo.Text = "✅"
-- 						usernameInfo.Color = Color(200, 200, 200, 255)
-- 						checkUsernameKey = res.key
-- 						checkUsernameError = nil
-- 					end

-- 					usernameInfo.pos.X = node.Width - usernameInfo.Width

-- 					if checkUsernameKey ~= nil then
-- 						if callback ~= nil then
-- 							callback(true, checkUsernameKey)
-- 						end
-- 					end
-- 				end)
-- 			end

-- 			if config.noTimer == true then
-- 				displayChecking()
-- 				request()
-- 			else
-- 				checkUsernameTimer = Timer(0.2, function()
-- 					displayChecking()
-- 					-- additional delay for api request
-- 					checkUsernameTimer = Timer(0.3, function()
-- 						usernameInfo.Color = Color(200, 200, 200, 255)
-- 						checkUsernameTimer = nil
-- 						request()
-- 					end)
-- 				end)
-- 				usernameInfo.Text = ""
-- 			end
-- 		end

-- 		usernameInfo.pos.X = node.Width - usernameInfo.Width

-- 		-- if r == true, it means request for server side checks has been scheduled
-- 		if r == false then
-- 			checkUsernameError = true
-- 			if callback ~= nil then
-- 				callback(false, nil)
-- 			end
-- 		end
-- 	end

-- 	local didStartTyping = false
-- 	usernameInput.onTextChange = function(self)
-- 		local backup = self.onTextChange
-- 		self.onTextChange = nil

-- 		local s = str:normalize(self.Text)
-- 		s = str:lower(s)

-- 		self.Text = s
-- 		self.onTextChange = backup

-- 		if didStartTyping == false and self.Text ~= "" then
-- 			didStartTyping = true
-- 			System:DebugEvent("SIGNUP_STARTED_TYPING_USERNAME")
-- 		end

-- 		checkUsernameKey = nil
-- 		checkUsernameError = nil
-- 		checkUsername()
-- 	end

-- 	local signUpButton = ui:createButton(" ✨ " .. str:upperFirstChar(loc("sign up", "button")) .. " ✨ ") -- , { textSize = "big" })
-- 	signUpButton:setParent(node)
-- 	signUpButton:setColor(Color(150, 200, 61), Color(240, 255, 240))

-- 	signUpButton.onRelease = function()
-- 		local dobOK = checkDOB({ errorIfIncomplete = true })

-- 		if dobOK ~= true then
-- 			return
-- 		end

-- 		local usernameCallback = function(ok, key)
-- 			if ok == true and type(key) == "string" then
-- 				local username = usernameInput.Text
-- 				local dob = string.format("%02d-%02d-%04d", _month, _day, _year)

-- 				local modal = content:getModalIfContentIsActive()
-- 				if modal and modal.onSubmit then
-- 					modal.onSubmit(username, key, dob)
-- 				end
-- 			end
-- 		end

-- 		checkUsername(usernameCallback, { errorIfEmpty = true, noTimer = true })
-- 	end

-- 	local tickListener

-- 	content.didBecomeActive = function()
-- 		tickListener = LocalEvent:Listen(LocalEvent.Name.Tick, function(dt)
-- 			if usernameInfoDT then
-- 				usernameInfoDT = usernameInfoDT + dt
-- 				usernameInfoDT = usernameInfoDT % 0.4

-- 				local currentFrame = math.floor(usernameInfoDT / 0.1)

-- 				if currentFrame ~= usernameInfoFrame then
-- 					usernameInfoFrame = currentFrame
-- 					if usernameInfoFrame == 0 then
-- 						usernameInfo.Text = loc("checking") .. "   "
-- 					elseif usernameInfoFrame == 1 then
-- 						usernameInfo.Text = loc("checking") .. ".  "
-- 					elseif usernameInfoFrame == 2 then
-- 						usernameInfo.Text = loc("checking") .. ".. "
-- 					else
-- 						usernameInfo.Text = loc("checking") .. "..."
-- 					end
-- 				end
-- 			end
-- 		end)
-- 	end

-- 	local maxWidth = function()
-- 		return Screen.Width - theme.modalMargin * 2
-- 	end

-- 	local maxHeight = function()
-- 		return Screen.Height - 100
-- 	end

-- 	local terms = ui:createFrame(Color(255, 255, 255, 200))

-- 	content.willResignActive = function()
-- 		if tickListener then
-- 			tickListener:Remove()
-- 			tickListener = nil
-- 		end
-- 		terms:remove()
-- 	end

-- 	local textColor = Color(100, 100, 100)
-- 	local linkColor = Color(4, 161, 255)
-- 	local linkPressedColor = Color(233, 89, 249)

-- 	local termsText = ui:createText(
-- 		loc("By clicking Sign Up, you are agreeing to the Terms of Use and aknowledging the Privacy Policy."),
-- 		textColor,
-- 		"small"
-- 	)
-- 	termsText:setParent(terms)

-- 	local termsBtn = ui:createButton(
-- 		"Terms",
-- 		{ textSize = "small", borders = false, shadow = false, underline = true, padding = false }
-- 	)
-- 	termsBtn:setColor(Color(0, 0, 0, 0), linkColor)
-- 	termsBtn:setColorPressed(Color(0, 0, 0, 0), linkPressedColor)
-- 	termsBtn:setParent(terms)
-- 	termsBtn.onRelease = function()
-- 		System:OpenWebModal("https://cu.bzh/terms")
-- 	end

-- 	local separator = ui:createText("-", textColor, "small")
-- 	separator:setParent(terms)

-- 	local privacyBtn = ui:createButton(
-- 		"Privacy",
-- 		{ textSize = "small", borders = false, shadow = false, underline = true, padding = false }
-- 	)
-- 	privacyBtn:setColor(Color(0, 0, 0, 0), linkColor)
-- 	privacyBtn:setColorPressed(Color(0, 0, 0, 0), linkPressedColor)
-- 	privacyBtn:setParent(terms)
-- 	privacyBtn.onRelease = function()
-- 		System:OpenWebModal("https://cu.bzh/privacy")
-- 	end

-- 	local position = function(modal, forceBounce)
-- 		termsText.object.MaxWidth = modal.Width - theme.paddingTiny * 2

-- 		local termsHeight = termsText.Height + termsBtn.Height + theme.paddingTiny * 3

-- 		local p = Number3(
-- 			Screen.Width * 0.5 - modal.Width * 0.5,
-- 			Screen.Height * 0.5 - modal.Height * 0.5 + (termsHeight + theme.padding) * 0.5,
-- 			0
-- 		)

-- 		if not modal.updatedPosition or forceBounce then
-- 			modal.LocalPosition = p - { 0, 100, 0 }
-- 			modal.updatedPosition = true
-- 			ease:outElastic(modal, 0.3).LocalPosition = p
-- 		else
-- 			modal.LocalPosition = p
-- 		end

-- 		terms.Width = modal.Width
-- 		terms.Height = termsHeight

-- 		terms.pos.X = p.X + modal.Width * 0.5 - terms.Width * 0.5
-- 		terms.pos.Y = p.Y + -terms.Height - theme.padding

-- 		termsText.pos.X = terms.Width * 0.5 - termsText.Width * 0.5
-- 		termsText.pos.Y = terms.Height - termsText.Height - theme.paddingTiny

-- 		local w = termsBtn.Width + separator.Width + privacyBtn.Width + theme.padding * 2

-- 		termsBtn.pos.Y = theme.paddingTiny
-- 		termsBtn.pos.X = terms.Width * 0.5 - w * 0.5

-- 		separator.pos.Y = theme.paddingTiny
-- 		separator.pos.X = termsBtn.pos.X + termsBtn.Width + theme.padding

-- 		privacyBtn.pos.Y = theme.paddingTiny
-- 		privacyBtn.pos.X = separator.pos.X + separator.Width + theme.padding
-- 	end

-- 	local popup = modal:create(content, maxWidth, maxHeight, position, ui)
-- 	popup.terms = terms

-- 	popup.onSuccess = function() end

-- 	popup.bounce = function(_)
-- 		position(popup, true)
-- 	end

-- 	node.refresh = function(self)
-- 		-- signUpButton.Width = nil
-- 		-- signUpButton.Width = signUpButton.Width * 1.5

-- 		self.Width = math.min(400, Screen.Width - Screen.SafeArea.Right - Screen.SafeArea.Left - theme.paddingBig * 2)
-- 		self.Height = birthdayLabel.Height
-- 			+ theme.paddingTiny
-- 			+ monthInput.Height
-- 			+ theme.padding
-- 			+ usernameLabel.Height
-- 			+ theme.paddingTiny
-- 			+ usernameInput.Height
-- 			+ theme.paddingBig
-- 			+ signUpButton.Height

-- 		birthdayLabel.pos.Y = self.Height - birthdayLabel.Height

-- 		birthdayInfo.pos.Y = birthdayLabel.pos.Y
-- 		birthdayInfo.pos.X = self.Width - birthdayInfo.Width

-- 		local thirdWidth = self.Width / 3.0

-- 		monthInput.Width = thirdWidth
-- 		monthInput.pos.Y = birthdayLabel.pos.Y - theme.paddingTiny - monthInput.Height

-- 		dayInput.Width = thirdWidth
-- 		dayInput.pos.X = monthInput.pos.X + monthInput.Width
-- 		dayInput.pos.Y = monthInput.pos.Y

-- 		yearInput.Width = thirdWidth
-- 		yearInput.pos.X = dayInput.pos.X + dayInput.Width
-- 		yearInput.pos.Y = dayInput.pos.Y

-- 		usernameLabel.pos.Y = monthInput.pos.Y - theme.padding - usernameLabel.Height

-- 		usernameInfo.pos.Y = usernameLabel.pos.Y
-- 		usernameInfo.pos.X = self.Width - usernameInfo.Width

-- 		usernameInput.Width = self.Width
-- 		usernameInput.pos.Y = usernameLabel.pos.Y - theme.paddingTiny - usernameInput.Height

-- 		signUpButton.pos.X = self.Width * 0.5 - signUpButton.Width * 0.5
-- 	end

-- 	return popup
-- end

return signup
