/* ============================================================
   1.1 화재 원자료 불러오기
   ============================================================ */

proc import datafile="/home/u63652680/NFA/fire_clean_for_sas.csv"
    out=work.fire_raw
    dbms=csv
    replace;
    getnames=yes;
    guessingrows=max;
run;

proc contents data=work.fire_raw varnum; run;

proc freq data=work.fire_raw;
    tables SIDO / nocum;
run;

/* ============================================================
   1.2 데이터 정제 - 결측치 확인 및 대체
   ============================================================ */
  
proc means data=work.fire_raw n nmiss;
    var CASUALTY DEATH INJURY DMG_TOTAL DMG_REAL DMG_MOVABLE;
run;

data work.fire_clean;
    set work.fire_raw;
    if missing(DMG_REAL) then DMG_REAL = 0;
    if missing(DMG_MOVABLE) then DMG_MOVABLE = 0;
run;

/* 완전 중복행 제거 */
proc sort data=work.fire_clean out=work.fire_dedup noduprecs;
    by _all_;
run;

/* ============================================================
   1.3 시군구 단위 집계
   ============================================================ */
proc sql;
    create table work.fire_agg as
    select SIDO, SIGUNGU,
           count(*) as FIRE_CNT,
           sum(DEATH) as DEATH_CNT,
           sum(INJURY) as INJURY_CNT,
           sum(DMG_TOTAL) as DMG_TOTAL_SUM
    from work.fire_dedup
    group by SIDO, SIGUNGU;
quit;

/* ============================================================
   1.4 인구 데이터 불러오기 및 조인 (수정: guessingrows=max 추가)
   ============================================================ */
proc import datafile="/home/u63652680/NFA/population_sigungu_avg.csv"
    out=work.pop_avg
    dbms=csv
    replace;
    getnames=yes;
    guessingrows=max;   /* 이게 빠져서 SIGUNGU 컬럼 길이가 짧게 잡혔었음 */
run;

proc sql;
    create table work.analysis as
    select a.SIDO, a.SIGUNGU, a.FIRE_CNT, a.DEATH_CNT, a.INJURY_CNT, a.DMG_TOTAL_SUM,
           b.POP_AVG_5YR,
           round(a.FIRE_CNT / b.POP_AVG_5YR * 100000, 0.01) as FIRE_RATE_100K
    from work.fire_agg as a
    left join work.pop_avg as b
    on a.SIDO = b.SIDO and a.SIGUNGU = b.SIGUNGU;
quit;

/* 병합 검증 - nmiss가 0이어야 정상 */
proc means data=work.analysis n nmiss;
    var POP_AVG_5YR;
run;

proc print data=work.analysis (obs=10);
    var SIDO SIGUNGU FIRE_CNT POP_AVG_5YR FIRE_RATE_100K;
run;

