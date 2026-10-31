-- Convert Readest server dates to Unix seconds without using the device zone.
-- The stock 0.12.16 plugin passes UTC fields to local os.time(), which shifts
-- incoming highlights and can move the next-sync cursor into the future.
local UTC = {}

function UTC.parse(value)
    if type(value) ~= "string" then return nil end
    local year, month, day, hour, minute, second, suffix =
        value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
    if not year then return nil end
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
    suffix = suffix:gsub("^%.%d+", "")
    local offset = 0
    if suffix ~= "Z" and suffix ~= "z" and suffix ~= "" then
        local sign, hours, minutes = suffix:match("^([+-])(%d%d):?(%d%d)$")
        if not sign then return nil end
        hours, minutes = tonumber(hours), tonumber(minutes)
        if hours > 23 or minutes > 59 then return nil end
        offset = (hours * 60 + minutes) * 60 * (sign == "+" and 1 or -1)
    end
    local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
    local lengths = {31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    if month < 1 or month > 12 or day < 1 or day > lengths[month]
        or hour > 23 or minute > 59 or second > 59 then return nil end
    -- Gregorian civil date -> days since 1970-01-01 (400-year eras).
    if month <= 2 then year = year - 1 end
    local era = math.floor(year / 400)
    local year_of_era = year - era * 400
    local adjusted_month = month + (month > 2 and -3 or 9)
    local day_of_year = math.floor((153 * adjusted_month + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4)
        - math.floor(year_of_era / 100) + day_of_year
    local days = era * 146097 + day_of_era - 719468
    return days * 86400 + hour * 3600 + minute * 60 + second - offset
end

return UTC
