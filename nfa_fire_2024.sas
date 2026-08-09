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

/* ============================================================
   3단계 통계검정 결과 정리

   [3.1 정규성 - Shapiro-Wilk]
     H0: 정규분포를 따른다 / H1: 따르지 않는다
     FIRE_CNT W=0.91737, FIRE_RATE_100K W=0.895889, 모두 p<0.0001
     -> H0 기각, 이후 그룹비교는 비모수검정으로 진행

   [3.2 군 vs 시·구 - Wilcoxon 2-sample(=Mann-Whitney U)]
     H0: 두 집단 FIRE_RATE_100K 분포 동일 / H1: 다르다
     Z=11.9032, p<.0001 / 군 중앙값 1017.06 vs 시구 320.37 (약 3.2배)
     -> H0 기각. 단, 분모(인구)가 작은 상태에서 임야·야외소각이 더해진 결과일 가능성
        2.1의 POP_AVG_5YR ~ FIRE_RATE_100K 상관 -0.794와 동일 현상

   [3.3 시도별 - Kruskal-Wallis]
     H0: 17개 시도 분포 모두 동일 / H1: 최소 하나가 다르다
     Chi-Square=117.7353, DF=16, p<.0001 -> H0 기각
     상위 전남/전북/강원, 하위 세종/인천/대구
     한계: 세종 n=1, 제주 n=2로 표본 극소. 어느 시도가 다른지는 사후검정 필요

   [3.4 발화요인 x 장소 - 카이제곱 독립성 검정]
     H0: 두 변수는 독립 / H1: 연관이 있다
     Chi-Square=59050.3023, DF=154, p<.0001, Cramer's V=0.1674
     -> H0 기각하나, n=191,509로 표본이 매우 커 p값은 거의 필연적으로 유의
        효과크기 V=0.167은 약~중간 수준의 연관성
     가정: 기대빈도 5 미만 셀 12.2% (기준 20% 이내) -> 검정 유효

   [3.5 과산포]
     평균 753.97, 분산 184499.62 -> 분산/평균 = 244.70
     -> 과산포 매우 심함, 음이항 회귀 병행 필요
     단, 이 값에는 인구규모 차이가 섞여있어 예비신호일 뿐
        실제 판단은 모델 적합 후 Deviance/DF로
   ============================================================ */
  
/* ============================================================
   4.1 오프셋 변수 생성
   ============================================================ */
data work.model_data;
    set work.analysis3;
    LOG_POP = log(POP_AVG_5YR);
run;

/* ============================================================
   4.2 포아송 회귀 (offset 지정)
   출력의 Deviance/DF, Pearson Chi-Square/DF가 1보다 훨씬 크면 과산포
   ============================================================ */
proc genmod data=work.model_data;
    model FIRE_CNT = CARELESS_RATIO RESIDENTIAL_RATIO WINTER_RATIO
          / dist=poisson link=log offset=LOG_POP;
run;

/* ============================================================
   4.3 음이항 회귀 (Dispersion 모수 추가 추정)
   ============================================================ */
proc genmod data=work.model_data;
    model FIRE_CNT = CARELESS_RATIO RESIDENTIAL_RATIO WINTER_RATIO
          / dist=negbin link=log offset=LOG_POP;
run;

/* ============================================================
   4단계 모델링 결과 해석

   [4.1 과산포 진단]
     포아송 : Deviance/DF=125.1582, Pearson/DF=145.9384, AIC=33403.4
     음이항 : Deviance/DF=1.0563,  Pearson/DF=1.0751,  AIC=3634.6
     -> 포아송 부적합(표준오차 과소추정), 음이항 채택 (AIC 29,769 감소)
     -> Dispersion=0.2107 (p<.0001), 포아송(alpha=0) 기각 근거
     -> 3.5의 244.70과 다른 이유: 오프셋으로 인구규모 효과 제거됨

   [4.2 계수 해석 - 변화단위 주의]
     변수              계수      SD      10%p RR    1SD RR
     CARELESS_RATIO    2.4736  0.0866   1.281      1.239 (+23.9%)
     RESIDENTIAL_RATIO -4.5923 0.0855   0.632      0.675 (-32.5%)
     WINTER_RATIO       5.9452 0.0287   1.812      1.186 (+18.6%)

     -> WINTER_RATIO는 SD가 0.0287로 작아 10%p = 3.49SD의 비현실적 외삽
        1SD 기준 재계산시 영향력 순위 역전:
        RESIDENTIAL > CARELESS > WINTER
     -> 2.3에서 예상한 "동절기 변동 작아 설명력 약함"이 확인됨

   [4.3 방향 해석]
     CARELESS_RATIO(+) : 부주의 비중 높은 지역일수록 인구당 발생율 높음 (3.2~3.3과 일치)
     RESIDENTIAL_RATIO(-) : 구성비 변수 특성. 군 주거22.0%/임야8.5% vs 시구 주거28.6%/임야2.5%
        -> "주거가 안전"이 아니라 "도시성 대리변수"로 해석해야 함
     구성비 변수는 합이 1로 묶여있어(compositional) 독립적 인과효과로 읽으면 안 됨

   [4.4 한계] Pseudo R2=0.047로 낮음. 산업구조/건축노후도/소방인프라 등 미포함
              관측된 연관성이며 인과관계 아님
   ============================================================ */
  
/* ============================================================
   4.5 모델 진단 - 잔차 분석
   output문으로 예측값(PRED)과 피어슨잔차(RESCHI)를 데이터셋으로 저장
   ============================================================ */
proc genmod data=work.model_data;
    model FIRE_CNT = CARELESS_RATIO RESIDENTIAL_RATIO WINTER_RATIO
          / dist=negbin link=log offset=LOG_POP;
    output out=work.negbin_out pred=PRED reschi=RESCHI resdev=RESDEV;
run;

proc sort data=work.negbin_out out=work.resid_sorted;
    by descending RESCHI;
run;

/* 예측보다 화재가 많은 지역 TOP 10 */
proc print data=work.resid_sorted (obs=10);
    var SIDO SIGUNGU FIRE_CNT PRED RESCHI FIRE_RATE_100K;
run;

/* 예측보다 화재가 적은 지역 TOP 10 */
proc sort data=work.negbin_out out=work.resid_asc; by RESCHI; run;
proc print data=work.resid_asc (obs=10);
    var SIDO SIGUNGU FIRE_CNT PRED RESCHI FIRE_RATE_100K;
run;

proc means data=work.negbin_out mean std min max;
    var RESCHI;
run;

/* ============================================================
   4.5 모델 진단 결과 해석

   [전반적 적합도] 잔차 평균 0.0043, SD 1.0307 -> 이상적(0,1)에 근접
                   |잔차|>3 : 254개 중 2개(양구군 3.75, 청송군 3.71), 0.8%

   [잔차 비대칭] 최대 +3.75 vs 최소 -1.82
     -> 모델 결함 아닌 구조적 특성. 화재건수는 0 미만 불가하므로
        예측값 큰 지역의 피어슨잔차 하한 = -1/sqrt(alpha) = -1/sqrt(0.2107) = -2.18
        위쪽은 상한 없어 꼬리가 길다. 상하위 대칭 비교 금물

   [!! 발견된 문제 - 지역유형별 체계적 편향]
     군지역(n=83)   잔차평균 +0.975
     시구지역(n=171) 잔차평균 -0.467
     -> 예측초과 TOP10 전부 군, 예측미달 TOP10 전부 시구
     -> 세 변수 통제 후에도 농촌 화재를 체계적으로 과소예측
     -> 전체 평균 0.0043이 양호해 보인 건 두 그룹 편향이 상쇄된 결과
        전체지표만 보면 놓침, 그룹별로 쪼개야 드러남
     -> 시도별로도 강원+0.788/충남+0.618 vs 세종-1.478/울산-0.942 동일 방향

   [원인 추정] 군 임야화재 8.5% vs 시구 2.5%
              농촌 야외·임야화재 미반영 = 누락변수 문제로 판단 -> 4.6에서 개선
   ============================================================ */
  
/* ============================================================
   4.6 모델 개선 - 누락변수 추가
   (임야화재비율은 Python에서 파생 후 CSV로 재업로드하거나,
    PROC SQL로 fire_dedup2에서 동일하게 계산)
   ============================================================ */
proc sql;
    create table work.deriv2 as
    select SIDO, SIGUNGU,
           mean(case when PLACE_L = '임야' then 1 else 0 end) as FOREST_RATIO format=6.4
    from work.fire_dedup2
    group by SIDO, SIGUNGU;
quit;

data work.model_data2;
    merge work.model_data (in=a) work.deriv2;
    by SIDO SIGUNGU;
    if a;
    GUN = (REGION_TYPE = 'GUN');
run;
proc sort data=work.model_data; by SIDO SIGUNGU; run;
proc sort data=work.deriv2;      by SIDO SIGUNGU; run;

/* 모델 A: 임야화재비율 추가 */
proc genmod data=work.model_data2;
    model FIRE_CNT = CARELESS_RATIO RESIDENTIAL_RATIO WINTER_RATIO FOREST_RATIO
          / dist=negbin link=log offset=LOG_POP;
    output out=work.out_a reschi=RESCHI_A;
run;

/* 모델 B: 군지역 더미 추가 */
proc genmod data=work.model_data2;
    model FIRE_CNT = CARELESS_RATIO RESIDENTIAL_RATIO WINTER_RATIO GUN
          / dist=negbin link=log offset=LOG_POP;
    output out=work.out_b reschi=RESCHI_B;
run;

/* 편향 해소 여부 확인 - 두 그룹 평균이 0에 가까워야 개선된 것 */
proc means data=work.out_a mean; class REGION_TYPE; var RESCHI_A; run;
proc means data=work.out_b mean; class REGION_TYPE; var RESCHI_B; run;

/* ============================================================
   4.5 -> 4.6 흐름
     모델링은 적합 -> 진단 -> 재설정 -> 재진단의 반복
     4.4: 전체 적합도(Dev/DF=1.06)만 보면 완성처럼 보였음
     4.5: 잔차를 지역유형별로 쪼개니 군 +0.975 / 시구 -0.467 체계적 편향
          전체평균 0.0043은 두 편향 상쇄로 문제를 감추고 있었음
     4.6: 체계적 편향 = 누락변수 신호 -> 변수 추가 후 편향 해소 확인
     ※ AIC 낮추려고 아무 변수나 넣는 것과 다름.
       임야화재비율은 4.3의 실질근거(군 8.5% vs 시구 2.5%)에서 나온 가설.
       진단이 먼저, 변수추가가 나중. 반대로 하면 과적합.

   [4.6 모델 비교]
     기본3변수      AIC=3634.6  군+0.975 시구-0.467
     A:+FOREST_RATIO AIC=3542.5  군+0.631 시구-0.301 (편향 약35% 감소)
     B:+GUN더미      AIC=3459.6  군+0.003 시구+0.002 (편향 해소)
     VIF 최대 1.43 -> 공선성 문제 없음

   [1SD 기준 발생율비]
                     모델A     모델B
     CARELESS_RATIO   +15.9%   +18.2%
     RESIDENTIAL     -22.7%   -24.2%
     WINTER          +12.7%    +8.1%
     FOREST          +36.0%      -
     GUN                -     2.13배

     -> GUN 계수 0.7544, exp=2.13. 구성비 통제 후에도 군지역 2.13배
     -> WINTER 계수 5.945 -> 4.179(A) -> 2.721(B)로 계속 감소
        기본모델에서 농촌효과를 대신 흡수하고 있었음 (누락변수 편의)

   [최종 채택] 모델 B
     이유: 체계적 편향 해소, 잔차진단 통과, 계수 신뢰 가능
     한계: 더미는 "농촌 2.13배"를 통제할 뿐 이유를 설명하지 않음
           임야화재(A)가 이유의 일부이나 전부는 아님
           남은 2.13배에 농업소각/주택노후/소방접근시간/고령화 등 미측정 요인 혼재

   [남은 잔차구조] |잔차|>3 여전히 2개(공주시 4.17, 포천시 3.50)
     시도별 충남+0.701/경북+0.568 vs 울산-1.015/대구-0.800
     공간적 자기상관 가능성 있으나 인접정보 필요 -> 범위 밖, 한계로 기록
   ============================================================ */
  
/* ============================================================
   5.1 AS-IS 현황 지표
   ============================================================ */
proc genmod data=work.model_data2;
    model FIRE_CNT = CARELESS_RATIO RESIDENTIAL_RATIO WINTER_RATIO GUN
          / dist=negbin link=log offset=LOG_POP;
    output out=work.final_out pred=PRED reschi=RESID;
run;

data work.final_out;
    set work.final_out;
    EXCESS = FIRE_CNT - PRED;
run;

proc means data=work.final_out sum median;
    class REGION_TYPE;
    var FIRE_CNT DEATH_CNT INJURY_CNT FIRE_RATE_100K;
run;

/* ============================================================
   5.2 개입 우선순위 지역 (잔차 기준 / 초과건수 기준)
   ============================================================ */
proc sort data=work.final_out out=work.by_resid;   by descending RESID;  run;
proc print data=work.by_resid (obs=10);
    var SIDO SIGUNGU REGION_TYPE FIRE_CNT PRED EXCESS RESID;
run;

proc sort data=work.final_out out=work.by_excess;  by descending EXCESS; run;
proc print data=work.by_excess (obs=10);
    var SIDO SIGUNGU REGION_TYPE FIRE_CNT PRED EXCESS RESID;
run;

/* ============================================================
   5.3 부주의 화재 소분류 - 지역유형별 구성비
   ============================================================ */
data work.careless;
    set work.fire_dedup2;
    if CAUSE_L = '부주의';
    length REGION_TYPE $6;
    if ksubstr(strip(SIGUNGU), klength(strip(SIGUNGU)), 1) = '군'
        then REGION_TYPE = 'GUN'; else REGION_TYPE = 'SI_GU';
run;

proc freq data=work.careless;
    tables REGION_TYPE * CAUSE_S / nocol nopercent;
run;

/* ============================================================
   5.4 군/시/구 3분류 잔차 재확인 (이분법의 한계 점검)
   ============================================================ */
data work.final_cat;
    set work.final_out;
    length REGION_CAT $4;
    if ksubstr(strip(SIGUNGU), klength(strip(SIGUNGU)), 1) = '군' then REGION_CAT = 'GUN';
    else if ksubstr(strip(SIGUNGU), klength(strip(SIGUNGU)), 1) = '구' then REGION_CAT = 'GU';
    else REGION_CAT = 'SI';
run;

proc means data=work.final_cat n mean median;
    class REGION_CAT;
    var RESID;
run;

/* ============================================================
   5.5 최종 모델 - 3분류(구/시/군) 재적합
   class문 + ref= 로 기준범주를 '구'로 지정
   ============================================================ */
proc genmod data=work.final_cat;
    class REGION_CAT (ref='GU') / param=ref;
    model FIRE_CNT = CARELESS_RATIO RESIDENTIAL_RATIO WINTER_RATIO REGION_CAT
          / dist=negbin link=log offset=LOG_POP;
    output out=work.out_c reschi=RESID_C;
run;

/* 편향 해소 검증 - 세 그룹 모두 0에 가까워야 함 */
proc means data=work.out_c mean;
    class REGION_CAT;
    var RESID_C;
run;

/* ============================================================
   5.1 AS-IS 현황 지표
   목적: 지역유형별 화재 부담의 크기를 숫자로 확정
   방법: 최종모델 예측값·잔차·초과건수 산출 후 지역유형별 집계
   결과: 발생율 중앙값 GUN 1017.06 vs SI_GU 320.37 (3.2배)
         화재 1000건당 사망 GUN 8.01명 vs SI_GU 8.27명
   해석: 농촌은 "더 치명적"이 아니라 "더 자주 나는" 화재
         -> 사후대응보다 발생억제가 우선

   ------------------------------------------------------------
   5.2 개입 우선순위 지역 도출
   목적: 어느 지역에 먼저 개입할지 데이터로 좁히기
   방법: 잔차(설명 안 되는 초과) / 초과건수(절대 감축여력) 두 기준 각 TOP10
   결과: 잔차기준   공주시 4.17, 포천시 3.51, 보령시 2.86
         초과건수기준 포천시 742건, 안성시 460건, 서귀포시 439건
   해석: 두 기준이 다른 지역을 지목 -> 함께 봐야 함
         양쪽 상위인 포천시·공주시·김제시가 최우선
         종로구는 유일 도심권 상위 -> 별도 검토

   ------------------------------------------------------------
   5.3 원인별 개입 지점 확인
   목적: 전체 47.4%인 '부주의'의 실제 내용 세분화
   방법: CAUSE_S를 지역유형별 구성비로 교차분석
   결과: 야외소각(쓰레기소각+논임야태우기) GUN 29.67% vs SI_GU 9.34% (3.2배)
         담배꽁초 SI_GU 35.66% vs GUN 18.38%
   해석: 농촌=야외소각, 도시=담배·조리. 전국 단일캠페인으로는 양쪽 다 놓침
   교훈: Python 상위8개 출력시 '논,임야태우기'(전체9위) 누락됨
         전체빈도 상위N 절단은 특정그룹 특화 범주를 가림

   ------------------------------------------------------------
   5.4 지역 분류체계의 한계 확인
   목적: 4.6의 군/시구 이분법이 충분했는지 검증
   방법: 잔차를 GU/GUN/SI 3분류로 재확인
   결과: GU -0.2988 / GUN +0.0031 / SI +0.4684
         잔차 TOP10 중 9곳이 도농복합시(공주·포천·보령·문경·김제·남원·영천·상주·당진)
   해석: 이분법이 도농복합시를 '도시'로 묶어 초과화재가 잔차로 남음
         -> 모델에 편향 잔존, 재설정 필요

   ------------------------------------------------------------
   5.5 최종 모델 - 3분류 재적합
   목적: 5.4의 편향이 분류 세분화로 해소되는지 검증
   방법: GU를 ref로 두고 REGION_CAT을 class 변수로 투입해 음이항 재적합
   결과: AIC 3459.6 -> 3426.9, Pseudo R2 0.071 -> 0.102
         잔차평균 GU +0.0017 / GUN +0.0031 / SI +0.0020 (세 그룹 모두 해소)
         Pearson Chi-Square/DF = 1.0024 (Deviance/DF = 1.0420)
         -> 음이항 기본 1.0751 -> +임야 1.0448 -> +GUN 1.0355 -> 3분류 1.0024
            지금까지 중 가장 이상적(1.0)에 근접
   해석: 5.4 가설 검증됨. 발생율비 GU기준 SI 1.41배, GUN 2.61배
         -> 도시성에 따른 단계적 격차, 이분법이 놓친 중간단계가 드러남
   한계: |잔차|>3 3곳(포천시 3.25, 종로구 3.25, 공주시 3.04) 잔존
         개별 지역 고유요인은 여전히 미설명
   ============================================================ */
  
/* ============================================================
   5단계 종합: 인사이트 (AS-IS -> TO-BE)

   ---------------- AS-IS ----------------
   [1] 화재 부담은 도시성에 따라 단계적으로 증가
       GU(104) 1.00 기준 / SI(67) 1.41배 / GUN(83) 2.61배
       - 원인·장소·계절 구성 통제 후 값
       - 이분법에서는 군 2.13배로만 보였으나 도농복합시 분리로 중간단계 발견

   [2] 화재의 47.4%가 부주의, 내용은 지역별 상이
       야외소각 합계  GUN 29.67% vs SI_GU  9.34% (3.2배)
         (쓰레기소각 23.70/7.72, 논임야태우기 5.97/1.62)
       담배꽁초      GUN 18.38% vs SI_GU 35.66%
       음식물조리중   GUN  5.58% vs SI_GU 17.12%

   [3] 화재 1건당 위험도는 지역차 작음
       화재 1000건당 사망 GUN 8.01명 vs SI_GU 8.27명

   ---------------- TO-BE ----------------
   [1] 지역 맞춤형 예방캠페인
       농촌: 영농부산물·생활쓰레기 소각 대체수단(파쇄지원), 소각허가시기 관리
       도시: 흡연구역 관리, 주방화재 예방(자동소화장치 보급)

   [2] 우선 개입지역 이중선정
       잔차기준(원인규명 필요) : 공주시, 포천시, 보령시, 문경시, 김제시
       초과건수기준(감축여력)  : 포천시, 안성시, 서귀포시, 종로구, 김제시
       양쪽 상위 -> 포천시, 공주시, 김제시 최우선

   [3] 도농복합시를 별도 정책대상으로
       SI는 GU 대비 1.41배, 도시로 분류되나 위험은 중간
       현행 도시형 예방정책이 농촌적 특성(야외소각) 미반영 가능성
       -> 행정구역 명칭이 아닌 인구밀도·임야면적비 등 실질지표 유형화 권장

   ---------------- 한계 ----------------
     - 관측된 연관성이며 인과관계 입증 아님
     - Pseudo R2 0.102, 지역차이의 일부만 설명
     - 산업구조/건축물노후도/소방서접근시간/고령화율 미포함
     - |잔차|>3 3개지역(포천시·종로구·공주시) 고유요인 미설명
     - 시도별 잔차의 공간적 자기상관 가능성, 인접정보 부재로 미처리
     - 군위군(2023.7 경북->대구) 등 관할변경 지역의 집계 이질성
     - 지역분류를 시군구 명칭 끝글자로 판정, 명칭과 실제특성 불일치 가능
   ============================================================ */
  
