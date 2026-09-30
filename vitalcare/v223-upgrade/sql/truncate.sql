-- 1. 대상 데이터베이스 선택
USE vitalcare;

-- 2. 현재 FOREIGN_KEY_CHECKS 상태 백업
SET @original_fk_checks = @@FOREIGN_KEY_CHECKS;

-- 3. TRUNCATE 충돌 방지를 위해 일시적으로 0 설정
SET FOREIGN_KEY_CHECKS = 0;

-- 4. 테이블 TRUNCATE 수행 (한 번에 실행됨)
TRUNCATE TABLE account_alarm_last_read;
TRUNCATE TABLE accounts_acting_history;
TRUNCATE TABLE accounts_actions;
TRUNCATE TABLE accounts_alarm_mutes_settings;
TRUNCATE TABLE accounts_column_preference;
TRUNCATE TABLE accounts_encounter_safety_notification_settings;
TRUNCATE TABLE accounts_favorite;
TRUNCATE TABLE accounts_hospital;
TRUNCATE TABLE accounts_logging;
TRUNCATE TABLE accounts_note;
TRUNCATE TABLE accounts_notification_history;
TRUNCATE TABLE accounts_notification_settings;
TRUNCATE TABLE accounts_pin;
TRUNCATE TABLE accounts_policy_agreement;
TRUNCATE TABLE accounts_report_history;
TRUNCATE TABLE accounts_settings;
TRUNCATE TABLE accounts_token;
TRUNCATE TABLE accounts_user;
TRUNCATE TABLE accounts_user_info;

TRUNCATE TABLE api_cov_setting_history;
TRUNCATE TABLE api_screeningrecord;

TRUNCATE TABLE bridge_laboratory;
TRUNCATE TABLE bridge_vitalsign;

TRUNCATE TABLE emr_actions;
TRUNCATE TABLE emr_consent;
TRUNCATE TABLE emr_current_dnr;
TRUNCATE TABLE emr_department;
TRUNCATE TABLE emr_dnr_history;
TRUNCATE TABLE emr_encounter;
TRUNCATE TABLE emr_encounter_department;
TRUNCATE TABLE emr_encounter_location;
TRUNCATE TABLE emr_encounter_practitioner;
TRUNCATE TABLE emr_encounter_status_history;
TRUNCATE TABLE emr_location;
TRUNCATE TABLE emr_observation;
TRUNCATE TABLE emr_patient;
TRUNCATE TABLE emr_practitioner;
TRUNCATE TABLE emr_score;

TRUNCATE TABLE failure_logging;
TRUNCATE TABLE scoring_eid_lock_target;
TRUNCATE TABLE system_logging;
TRUNCATE TABLE system_storage_alert;

TRUNCATE TABLE vc_event;
TRUNCATE TABLE vc_event_last_dispatched;
TRUNCATE TABLE vc_event_last_read;
TRUNCATE TABLE vc_event_last_screened;
TRUNCATE TABLE vc_icu;
TRUNCATE TABLE vc_observation;

-- 5. 처음에 백업해둔 원래 상태로 복구
SET FOREIGN_KEY_CHECKS = @original_fk_checks;
