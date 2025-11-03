-- ASUMSI: ID Benchmark yang dipilih adalah EMP100039, EMP100758, EMP101379, EMP101894, EMP101970
-- Bobot TGV Final: Perilaku 40%, Kognitif 35%, Kompetensi 20%, Kontekstual 5%

-- =========================================================
-- TAHAP 1: MENGHITUNG BENCHMARK BASELINE (PROFIL IDEAL)
-- =========================================================

WITH Benchmark_IDs AS (
    SELECT unnest(ARRAY['EMP100039', 'EMP100758', 'EMP101379', 'EMP101894', 'EMP101970']) AS employee_id
),

Papi_Benchmark AS (
    -- Median PAPI Numerik (Papi_D)
    SELECT
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.score) AS benchmark_papi_d
    FROM papi_scores p
    WHERE p.employee_id IN (SELECT employee_id FROM Benchmark_IDs)
    AND p.scale_code = 'Papi_D'
),

Competency_Benchmark AS (
    -- Median Kompetensi (FTC)
    SELECT
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cy.score) AS benchmark_ftc_score
    FROM competencies_yearly cy
    WHERE cy.employee_id IN (SELECT employee_id FROM Benchmark_IDs)
    AND cy.pillar_code = 'FTC'
),

Kognitif_Benchmark AS (
    -- Median Kognitif (TIKI, Pauli)
    SELECT
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ps.pauli) AS benchmark_pauli,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ps.tiki) AS benchmark_tiki
    FROM profiles_psych ps
    WHERE ps.employee_id IN (SELECT employee_id FROM Benchmark_IDs)
),

Contextual_Benchmark AS (
    -- Median Kontekstual (Years of Service)
    SELECT
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY e.years_of_service_months) AS benchmark_yos
    FROM employees e
    WHERE e.employee_id IN (SELECT employee_id FROM Benchmark_IDs)
),

-- =========================================================
-- OPTIMASI: CTE PRA-AGREGASI
-- =========================================================

Papi_Scores_Pivoted AS (
    SELECT
        employee_id,
        MAX(CASE WHEN p.scale_code = 'Papi_D' THEN p.score END) AS user_papi_d
    FROM papi_scores p
    GROUP BY employee_id
),

Strengths_Aggregated AS (
    -- Mengambil Tema Rank 1 (Empathy)
    SELECT
        employee_id,
        MAX(CASE WHEN s.rank = 1 AND s.theme = 'Empathy' THEN 1 ELSE 0 END) AS user_strength_empathy
    FROM strengths s
    GROUP BY employee_id
),

Competency_Aggregated AS (
    -- Mengambil Skor FTC
    SELECT
        employee_id,
        MAX(CASE WHEN cy.pillar_code = 'FTC' THEN cy.score ELSE NULL END) AS user_ftc_score
    FROM competencies_yearly cy
    GROUP BY employee_id
),

-- =========================================================
-- TAHAP 3: MENGGABUNGKAN SKOR KANDIDAT & MENGHITUNG TV MATCH RATE
-- =========================================================

Candidate_Talent_Scores AS (
    -- CTE 2A: Mengumpulkan semua skor TV dari SEMUA karyawan (Kandidat)
    SELECT
        e.employee_id,
        e.fullname,
        e.years_of_service_months AS user_yos,
        e.education_id,
        de.name AS user_education,
        ps.pauli AS user_pauli,
        ps.tiki AS user_tiki,
        ps.disc AS user_disc,
        ps.mbti AS user_mbti,
        pp.user_papi_d,
        sa.user_strength_empathy,
        ca.user_ftc_score
    FROM employees e
    LEFT JOIN profiles_psych ps ON e.employee_id = ps.employee_id
    LEFT JOIN dim_education de ON e.education_id = de.education_id
    LEFT JOIN Papi_Scores_Pivoted pp ON e.employee_id = pp.employee_id 
    LEFT JOIN Strengths_Aggregated sa ON e.employee_id = sa.employee_id 
    LEFT JOIN Competency_Aggregated ca ON e.employee_id = ca.employee_id
),

TV_Match_Rate AS (
    -- CTE 2B: Menerapkan Logika Match Rate (Normal, Inversi, Boolean)
    SELECT
        cts.employee_id,
        cts.fullname,
        
        -- Mengambil Benchmark Baseline (Subquery/Skalar)
        (SELECT benchmark_pauli FROM Kognitif_Benchmark) AS b_pauli,
        (SELECT benchmark_tiki FROM Kognitif_Benchmark) AS b_tiki,
        (SELECT benchmark_papi_d FROM Papi_Benchmark) AS b_papi_d,
        (SELECT benchmark_ftc_score FROM Competency_Benchmark) AS b_ftc,
        (SELECT benchmark_yos FROM Contextual_Benchmark) AS b_yos,

        -- 1. TV Match Rate: KOGNITIF
        (CASE WHEN cts.user_tiki IS NULL THEN 0.0 ELSE LEAST( (cts.user_tiki / (SELECT benchmark_tiki FROM Kognitif_Benchmark)) * 100, 100.0) END) AS match_tiki,
        (CASE WHEN cts.user_pauli IS NULL THEN 0.0 ELSE LEAST( (cts.user_pauli / (SELECT benchmark_pauli FROM Kognitif_Benchmark)) * 100, 100.0) END) AS match_pauli,

        -- 2. TV Match Rate: PERILAKU (Papi D Normal, Boolean)
        (CASE WHEN cts.user_papi_d IS NULL THEN 0.0 ELSE LEAST( (cts.user_papi_d / (SELECT benchmark_papi_d FROM Papi_Benchmark)) * 100, 100.0) END) AS match_papi_d,
        
        -- DISC (Boolean: 'CS' = 100%)
        (CASE WHEN cts.user_disc = 'CS' THEN 100.0 ELSE 0.0 END) AS match_disc,

        -- MBTI (Boolean: 'ENFP' = 100%)
        (CASE WHEN cts.user_mbti = 'ENFP' THEN 100.0 ELSE 0.0 END) AS match_mbti,

        -- STRENGTHS (Boolean: 'Empathy' = 100%)
        (CASE WHEN cts.user_strength_empathy = 1 THEN 100.0 ELSE 0.0 END) AS match_strength,
        
        -- 3. TV Match Rate: KOMPETENSI (FTC)
        (CASE WHEN cts.user_ftc_score IS NULL THEN 0.0 ELSE LEAST( (cts.user_ftc_score / (SELECT benchmark_ftc_score FROM Competency_Benchmark)) * 100, 100.0) END) AS match_ftc,

        -- 4. TV Match Rate: KONTEKSTUAL
        -- Education (Boolean: 'S1' = 100%)
        (CASE WHEN cts.user_education = 'S1' THEN 100.0 ELSE 0.0 END) AS match_education,
        -- Years of Service
        (CASE WHEN cts.user_yos IS NULL THEN 0.0 ELSE LEAST( (cts.user_yos / (SELECT benchmark_yos FROM Contextual_Benchmark)) * 100, 100.0) END) AS match_yos
        
    FROM Candidate_Talent_Scores cts
),

TGV_Match_Rate AS (
    -- CTE 3: Menghitung Skor TGV
    SELECT
        tmr.employee_id,
        tmr.fullname,
        
        -- EXPOSE ALL TV MATCH RATES
        tmr.match_tiki, tmr.match_pauli, tmr.match_papi_d, 
        tmr.match_disc, tmr.match_mbti, tmr.match_strength, tmr.match_ftc, tmr.match_education, tmr.match_yos,

        -- 1. TGV KOGNITIF (35% total)
        (
            (tmr.match_tiki * 0.50) + -- TIKI (40%)
            (tmr.match_pauli * 0.50)  -- Pauli (20%)
        ) AS tgv_kognitif_match,

        -- 2. TGV PERILAKU (40% total)
        (
            (tmr.match_papi_d * 0.40) + -- Papi D (35%)
            (tmr.match_disc * 0.25) + -- DISC (20% Boolean)
            (tmr.match_mbti *0.25) +
            (tmr.match_strength * 0.10) -- Strengths (10% Boolean)
        ) AS tgv_perilaku_match,

        -- 3. TGV KOMPETENSI (20% total)
        (
            (tmr.match_ftc * 1.00) 
        ) AS tgv_kompetensi_match,

        -- 4. TGV KONTEKSTUAL (5% total)
        (
            (tmr.match_education * 0.70) + 
            (tmr.match_yos * 0.30)
        ) AS tgv_kontekstual_match
    FROM TV_Match_Rate tmr
)

-- Kueri Final: Menghitung Final Match Rate
SELECT
    tmr.employee_id,
    tmr.fullname,
    
    -- TAHAP 4: Menerapkan Bobot TGV Final
    (tmr.tgv_kognitif_match * 0.35) + 
    (tmr.tgv_perilaku_match * 0.40) + 
    (tmr.tgv_kompetensi_match * 0.20) + 
    (tmr.tgv_kontekstual_match * 0.05) 
    AS final_match_rate,
    
    -- Kolom pendukung
    tmr.tgv_kognitif_match,
    tmr.tgv_perilaku_match,
    tmr.match_tiki, 
    (SELECT benchmark_tiki FROM Kognitif_Benchmark) AS b_tiki, 

    -- Employee Information
    e.position_id,
    e.grade_id,
    e.directorate_id,
    de.name AS education_name
    
FROM TGV_Match_Rate tmr
LEFT JOIN employees e ON tmr.employee_id = e.employee_id
LEFT JOIN dim_education de ON e.education_id = de.education_id
ORDER BY final_match_rate DESC;