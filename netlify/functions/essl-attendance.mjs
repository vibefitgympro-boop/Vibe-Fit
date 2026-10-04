import { createHash, timingSafeEqual } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { gymDateKey, gymDateStartUtc, gymDateTimeToUtc, shiftDateKey } from "../../src/lib/gym-time.ts";

const MAX_BODY_BYTES = 1_000_000;

function json(status, payload) {
  return Response.json(payload, {
    status,
    headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" },
  });
}

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function createSupabaseFetch(apiKey) {
  return (input, init) => {
    const headers = new Headers(typeof Request !== "undefined" && input instanceof Request ? input.headers : undefined);
    if (init?.headers) new Headers(init.headers).forEach((value, key) => headers.set(key, value));
    if (apiKey.startsWith("sb_secret_") && headers.get("Authorization") === `Bearer ${apiKey}`) headers.delete("Authorization");
    headers.set("apikey", apiKey);
    return fetch(input, { ...init, headers });
  };
}

function createAdminClient() {
  const apiKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
  return createClient(requiredEnv("SUPABASE_URL"), apiKey, {
    global: { fetch: createSupabaseFetch(apiKey) },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function normalizeRecords(payload) {
  if (Array.isArray(payload)) return payload;
  if (!payload || typeof payload !== "object") return null;
  if (typeof payload.data === "string") return null; // Encrypted payloads are deliberately rejected; use the HTTPS URL token instead.
  for (const key of ["records", "logs", "data"]) {
    if (Array.isArray(payload[key])) return payload[key];
    if (payload[key] && typeof payload[key] === "object") return [payload[key]];
  }
  return [payload];
}

function getText(record, keys) {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" || typeof value === "number") {
      const text = String(value).trim();
      if (text) return text;
    }
  }
  return "";
}

function parsePunchDate(value, timeZone) {
  const local = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?$/.exec(value);
  if (local) {
    const [, yearText, monthText, dayText, hourText, minuteText, secondText, fraction = ""] = local;
    const year = Number(yearText), month = Number(monthText), day = Number(dayText);
    const hour = Number(hourText), minute = Number(minuteText), second = Number(secondText);
    const check = new Date(Date.UTC(year, month - 1, day, hour, minute, second));
    if (check.getUTCFullYear() !== year || check.getUTCMonth() + 1 !== month || check.getUTCDate() !== day || hour > 23 || minute > 59 || second > 59) return null;
    const base = gymDateTimeToUtc(`${yearText}-${monthText}-${dayText}`, `${hourText}:${minuteText}`, timeZone);
    base.setUTCSeconds(second, Number(fraction.padEnd(3, "0")));
    return base;
  }
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function makeEventId(serialNumber, employeeCode, occurredAt, record) {
  const workCode = getText(record, ["WorkCode", "workCode"]);
  const direction = getText(record, ["Direction", "direction"]);
  const verification = getText(record, ["VerificationType", "TransactionMode", "verificationType"]);
  const digest = createHash("sha256").update(`${serialNumber}|${employeeCode}|${occurredAt.toISOString()}|${direction}|${workCode}|${verification}`).digest("hex");
  return `essl:${digest}`;
}

function isExitPunch(record) {
  return ["out", "exit", "1"].includes(getText(record, ["Direction", "direction"]).toLowerCase());
}

async function membershipEligible(db, memberId, day) {
  const { data, error } = await db.from("memberships").select("id")
    .eq("member_id", memberId).eq("status", "active")
    .lte("starts_on", day).gte("ends_on", day).limit(1);
  if (error) throw new Error(`Could not check membership eligibility: ${error.message}`);
  return Boolean(data?.length);
}

async function handlePunch(db, record, deviceCache, mappingCache, timeZone) {
  if (!record || typeof record !== "object" || Array.isArray(record)) throw new Error("Webhook contains an invalid punch record.");
  const serialNumber = getText(record, ["SerialNumber", "serialNumber", "DeviceSerialNumber"]);
  const employeeCode = getText(record, ["EmployeeCode", "employeeCode", "UserId", "PIN", "Pin"]);
  const dateValue = getText(record, ["LogDate", "LogDateTime", "PunchTime", "checkTime"]);
  if (!serialNumber || !employeeCode || !dateValue) throw new Error("Punch record must include SerialNumber, EmployeeCode/UserId, and LogDate/LogDateTime.");
  const occurredAt = parsePunchDate(dateValue, timeZone);
  if (!occurredAt) throw new Error("Punch record contains an invalid local date/time.");
  const externalEventId = makeEventId(serialNumber, employeeCode, occurredAt, record);
  const { data: priorEvent, error: priorError } = await db.from("access_events").select("id").eq("external_event_id", externalEventId).maybeSingle();
  if (priorError) throw new Error(`Could not check duplicate event: ${priorError.message}`);
  if (priorEvent) return { duplicate: true, recorded: false };

  let device = deviceCache.get(serialNumber);
  if (device === undefined) {
    const { data, error } = await db.from("access_devices").select("id, active, external_id").eq("vendor", "eSSL").eq("external_id", serialNumber).maybeSingle();
    if (error) throw new Error(`Could not find the registered eSSL device: ${error.message}`);
    device = data ?? null;
    deviceCache.set(serialNumber, device);
  }
  if (!device) return { duplicate: false, recorded: false, unregisteredDevice: true };

  let mapping = mappingCache.get(`${device.id}:${employeeCode}`);
  if (mapping === undefined) {
    const { data, error } = await db.from("essl_member_mappings").select("member_id").eq("device_id", device.id).eq("device_user_id", employeeCode).eq("active", true).maybeSingle();
    if (error) throw new Error(`Could not load member mapping: ${error.message}`);
    mapping = data ?? null;
    mappingCache.set(`${device.id}:${employeeCode}`, mapping);
  }

  let memberId = mapping?.member_id ?? null;
  let decision = "denied";
  let reason = !device.active ? "Biometric device is inactive." : !mapping ? "Device employee ID is not mapped to a gym member." : null;
  let attendanceRecorded = false;
  if (device.active && mapping) {
    const { data: member, error: memberError } = await db.from("members").select("id, status").eq("id", mapping.member_id).maybeSingle();
    if (memberError) throw new Error(`Could not read mapped member: ${memberError.message}`);
    const localDay = gymDateKey(occurredAt, timeZone);
    if (!member || member.status !== "active") reason = "Mapped member is not active.";
    else if (!await membershipEligible(db, member.id, localDay)) reason = "Member has no active membership on the punch date.";
    else {
      decision = "granted";
      if (isExitPunch(record)) reason = "Exit punch received; attendance check-in was not duplicated.";
      else {
        const start = gymDateStartUtc(localDay, timeZone).toISOString();
        const end = gymDateStartUtc(shiftDateKey(localDay, 1), timeZone).toISOString();
        const { data: existing, error: attendanceLookupError } = await db.from("attendance").select("id").eq("member_id", member.id)
          .gte("checked_in_at", start).lt("checked_in_at", end).limit(1).maybeSingle();
        if (attendanceLookupError) throw new Error(`Could not check same-day attendance: ${attendanceLookupError.message}`);
        if (existing) reason = "Member already checked in for this gym-local day.";
        else {
          const { error: attendanceError } = await db.from("attendance").insert({
            member_id: member.id,
            checked_in_at: occurredAt.toISOString(),
            source: "essl",
            external_event_id: externalEventId,
          });
          if (attendanceError?.code === "23505") reason = "This punch was already recorded.";
          else if (attendanceError) throw new Error(`Could not save attendance: ${attendanceError.message}`);
          else { attendanceRecorded = true; reason = "Biometric attendance recorded."; }
        }
      }
    }
  }

  const { error: eventError } = await db.from("access_events").insert({
    device_id: device.id,
    member_id: memberId,
    external_event_id: externalEventId,
    decision,
    reason,
    occurred_at: occurredAt.toISOString(),
  });
  if (eventError && eventError.code !== "23505") throw new Error(`Could not save biometric event: ${eventError.message}`);
  return { duplicate: Boolean(eventError?.code === "23505"), recorded: attendanceRecorded, deviceId: device.id };
}

export default async function esslAttendanceWebhook(request) {
  if (request.method !== "POST") return json(405, { StatusCode: "405", Message: "POST required" });
  const url = new URL(request.url);
  const providedToken = url.searchParams.get("token") || "";
  if (providedToken.length < 32 || providedToken.length > 256) return json(401, { StatusCode: "401", Message: "Unauthorized" });
  const rawBody = await request.text();
  if (Buffer.byteLength(rawBody, "utf8") > MAX_BODY_BYTES) return json(413, { StatusCode: "413", Message: "Payload too large" });

  let payload;
  try { payload = JSON.parse(rawBody); }
  catch { return json(400, { StatusCode: "400", Message: "Invalid JSON payload" }); }
  const records = normalizeRecords(payload);
  if (!records) return json(400, { StatusCode: "400", Message: "Disable eBioServer payload encryption and send JSON records over HTTPS." });
  if (records.length > 500) return json(413, { StatusCode: "413", Message: "Too many punch records in one request" });

  try {
    const db = createAdminClient();
    const { data: config, error: configError } = await db.from("essl_webhook_config").select("token_hash").eq("id", 1).maybeSingle();
    if (configError) throw new Error(`Could not read webhook configuration: ${configError.message}`);
    const expected = config?.token_hash ? Buffer.from(config.token_hash, "hex") : Buffer.alloc(0);
    const provided = createHash("sha256").update(providedToken).digest();
    if (!expected.length || expected.length !== provided.length || !timingSafeEqual(expected, provided)) {
      return json(401, { StatusCode: "401", Message: "Unauthorized" });
    }

    const { data: gym, error: gymError } = await db.from("gym_settings").select("timezone").order("updated_at", { ascending: false }).limit(1).maybeSingle();
    if (gymError) throw new Error(`Could not read gym timezone: ${gymError.message}`);
    const timeZone = gym?.timezone || "Asia/Kolkata";
    const deviceCache = new Map();
    const mappingCache = new Map();
    let recorded = 0, duplicates = 0, deniedOrUnregistered = 0;
    for (const record of records) {
      const result = await handlePunch(db, record, deviceCache, mappingCache, timeZone);
      if (result.recorded) recorded += 1;
      if (result.duplicate) duplicates += 1;
      if (result.unregisteredDevice || (!result.recorded && !result.duplicate)) deniedOrUnregistered += 1;
    }
    for (const deviceId of new Set([...deviceCache.values()].filter(Boolean).map((device) => device.id))) {
      const { error } = await db.from("access_devices").update({ last_seen_at: new Date().toISOString() }).eq("id", deviceId);
      if (error) throw new Error(`Could not update biometric device heartbeat: ${error.message}`);
    }
    console.info("eSSL attendance webhook accepted", JSON.stringify({ received: records.length, recorded, duplicates, deniedOrUnregistered }));
    return json(200, { StatusCode: "200", Message: "Success" });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown webhook error.";
    console.error("eSSL attendance webhook failed:", message);
    return json(500, { StatusCode: "500", Message: "Attendance processing failed; retry the delivery." });
  }
}

