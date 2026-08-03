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

/* ============================================================
   2.1 데이터 탐색 - 기초 통계량 (평균 vs 중앙값으로 왜도 확인)
   ============================================================ */
proc means data=work.analysis n mean median std min max skew;
    var FIRE_CNT DEATH_CNT INJURY_CNT DMG_TOTAL_SUM POP_AVG_5YR FIRE_RATE_100K;
run;

/* ============================================================
   2.1-2 이상치 탐색 (PROC UNIVARIATE - 극단관측치 자동 출력)
   ============================================================ */
proc univariate data=work.analysis plot;
    var FIRE_CNT DMG_TOTAL_SUM FIRE_RATE_100K;
    id SIDO SIGUNGU; /* 이상치의 이름표를 달아주는 기능 */
run;

/* ============================================================
   2.1-3 변수간 상관분석 (Spearman)
   ============================================================ */
proc corr data=work.analysis spearman;
    var FIRE_CNT DEATH_CNT INJURY_CNT DMG_TOTAL_SUM POP_AVG_5YR FIRE_RATE_100K;
run;

/* ============================================================
   2.1 데이터 탐색 결과 해석

   [분포]
   - FIRE_CNT(왜도1.40), INJURY_CNT(1.32) 중간 치우침
   - DEATH_CNT(4.26), DMG_TOTAL_SUM(8.34) 심한 치우침
   - FIRE_RATE_100K(0.77)는 인구 정규화만으로 왜도 대폭 감소, IQR 이상치 0개
     -> 모델링은 FIRE_RATE_100K를 직접 종속변수로 쓰지 않고
        FIRE_CNT를 종속변수, POP_AVG_5YR을 오프셋으로 쓰는 포아송/음이항 회귀로 진행 예정

   [이상치]
   - FIRE_CNT 상위 이상치(화성시,김해시,평택시,강남구 등) : 대도시/신도시 규모효과, 정상
   - DMG_TOTAL_SUM 이상치 26건(전체 10%) : 이천시 최댓값(5,710억)은
     2021년 대형 물류센터 화재 단일사건(약 4,743억, 83%)이 대부분 -> 드문 대형사고에 좌우

   [상관분석]
   - FIRE_CNT - POP_AVG_5YR : 0.771 (규모효과)
   - POP_AVG_5YR - FIRE_RATE_100K : -0.794 (비율의 분모와의 상관 -> 일부 계산구조상 발생, 해석 주의)
   - DMG_TOTAL_SUM - FIRE_RATE_100K : 0.076, 비유의(p=0.23) -> 피해액은 발생빈도와 무관

   [변수 역할 정리]
   - DEATH_CNT, INJURY_CNT, DMG_TOTAL_SUM : 화재의 결과 -> 예측변수 제외, 종속변수 후보로 보류
   - POP_AVG_5YR : 예측변수가 아니라 오프셋(노출량)
   ============================================================ */

/* ============================================================
   2.3 파생변수 생성 - 원인·장소·계절 구성비
   (guessingrows=max로 재import 필요 - FIRE_MONTH 컬럼 추가됨)
   ============================================================ */

proc import datafile="/home/u63652680/NFA/fire_clean_for_sas.csv"
    out=work.fire_raw2
    dbms=csv
    replace;
    getnames=yes;
    guessingrows=max;
run;

data work.fire_dedup2;
    set work.fire_raw2;
run;
proc sort data=work.fire_dedup2 nodupkey; by _all_; run;

proc sql;
    create table work.deriv as
    select SIDO, SIGUNGU,
           mean(case when CAUSE_L = '부주의' then 1 else 0 end) as CARELESS_RATIO format=6.4,
           mean(case when PLACE_L = '주거' then 1 else 0 end) as RESIDENTIAL_RATIO format=6.4,
           mean(case when FIRE_MONTH in (12,1,2) then 1 else 0 end) as WINTER_RATIO format=6.4
    from work.fire_dedup2
    group by SIDO, SIGUNGU;
quit;

proc sql;
    create table work.analysis2 as
    select a.*, d.CARELESS_RATIO, d.RESIDENTIAL_RATIO, d.WINTER_RATIO
    from work.analysis as a
    left join work.deriv as d
    on a.SIDO = d.SIDO and a.SIGUNGU = d.SIGUNGU;
quit;

proc means data=work.analysis2 n nmiss mean std min max;
    var CARELESS_RATIO RESIDENTIAL_RATIO WINTER_RATIO;
run;

/* ============================================================
   2.3 파생변수 결과 해석

   - 부주의화재비율 평균(47.46%), 주거시설화재비율 평균(27.53%)이
     전국 비율(47.5%, 27.3%)과 근접 -> 계산 검증됨
     (단, describe 평균은 시군구 단순평균, 전국비율은 건수 가중평균으로 계산방식 다름)

   - 동절기화재비율 표준편차(0.029)가 다른 두 변수(0.087,0.085)보다 훨씬 작음
     -> 계절성은 전국적으로 균일, 지역간 설명력은 약할 가능성 -> 회귀 유의성 확인 필요

   - 부주의화재비율 최저: 울릉군(7.0%, 5년 43건으로 표본 최소)
     -> 표본이 작아 비율 추정이 불안정할 가능성, 대신 전기적요인(46.5%)/미상(37.2%) 높음
   - 부주의화재비율 최고: 보성군/남해군/순창군/하동군(전남경남 농촌, 60~70%)
     -> 농촌지역 소각 관련 부주의화재 패턴과 일치, 정책적 의미 있는 패턴으로 판단
   ============================================================ */
  
/* ============================================================
   2.4 다중공선성 점검 (상관분석 + VIF)
   ============================================================ */
proc corr data=work.analysis2 spearman;
    var CARELESS_RATIO RESIDENTIAL_RATIO WINTER_RATIO POP_AVG_5YR;
run;

/* VIF는 종속변수가 무엇이든 예측변수 구조만으로 계산되므로 FIRE_CNT를 임시로 사용 */
proc reg data=work.analysis2;
    model FIRE_CNT = CARELESS_RATIO RESIDENTIAL_RATIO WINTER_RATIO POP_AVG_5YR / vif tol;
run;
quit;

/* ============================================================
   2.4~2.5 다중공선성 점검 및 최종 변수선택

   [VIF] 전부 1.07~1.23 -> 기준선(5,10) 미달, 다중공선성 없음, 제거변수 없음
   [상관] 예측변수간 최대 0.365 (RESIDENTIAL_RATIO ~ POP_AVG_5YR)

   [참고] VIF 산출용 OLS에서 WINTER_RATIO p=0.1021 비유의
          -> 2.3의 "지역간 변동 작아 설명력 약할 것" 예상과 일치
          -> 단 카운트데이터에 부적합한 모델이므로 계수해석 보류,
             최종 판단은 4단계 포아송/음이항 회귀에서

   [최종 변수 확정]
     종속변수  : FIRE_CNT
     오프셋    : POP_AVG_5YR
     예측변수  : CARELESS_RATIO, RESIDENTIAL_RATIO, WINTER_RATIO
     분석제외  : DEATH_CNT, INJURY_CNT, DMG_TOTAL_SUM (화재의 결과변수)
   ============================================================ */
  
/* ============================================================
   3.1 정규성 검정 (normal 옵션 -> Shapiro-Wilk 등 출력)
   ============================================================ */
proc univariate data=work.analysis2 normal;
    var FIRE_CNT FIRE_RATE_100K;
run;

/* ============================================================
   3.2 지역유형 파생 (군 / 시·구)
   한글 마지막 글자 판별은 DBCS 대응 K함수(ksubstr, klength) 사용
   ============================================================ */
data work.analysis3;
    set work.analysis2;
    length REGION_TYPE $6;
    if ksubstr(strip(SIGUNGU), klength(strip(SIGUNGU)), 1) = '군'
        then REGION_TYPE = 'GUN';
        else REGION_TYPE = 'SI_GU';
run;

/* 검증: GUN 83 / SI_GU 171 이어야 정상 (Python 결과와 대조) */
proc freq data=work.analysis3;
    tables REGION_TYPE;
run;

/* ============================================================
   3.2-2 군 vs 시·구 화재발생율 차이 (Wilcoxon 2-sample = Mann-Whitney U)
   ============================================================ */
proc npar1way data=work.analysis3 wilcoxon;
    class REGION_TYPE;
    var FIRE_RATE_100K;
run;

/* ============================================================
   3.3 시도별 화재발생율 차이 (Kruskal-Wallis)
   NPAR1WAY는 그룹이 3개 이상이면 자동으로 Kruskal-Wallis를 출력한다
   ============================================================ */
proc npar1way data=work.analysis3 wilcoxon;
    class SIDO;
    var FIRE_RATE_100K;
run;

/* ============================================================
   3.4 발화요인 × 장소 독립성 검정 (카이제곱 + Cramer's V)
   ============================================================ */
proc freq data=work.fire_dedup2;
    tables CAUSE_L * PLACE_L / chisq norow nocol nopercent;
run;

/* ============================================================
   3.5 과산포 확인 (분산/평균 비율)
   ============================================================ */
proc means data=work.analysis3 mean var;
    var FIRE_CNT;
run;
