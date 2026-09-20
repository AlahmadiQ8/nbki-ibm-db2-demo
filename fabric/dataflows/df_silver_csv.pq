// df_silver_csv — Power Query (M) for the Dataflow Gen2 that cleans the
// hand-made Equation extracts.
//
// HOW TO USE THIS
// ---------------
// 1. Run `scripts/24_upload_csv_drop.py` so the CSVs are in
//    lh_bronze/Files/csv_drop/ where Fabric can reach them.
// 2. New item -> Dataflow Gen2 -> Get data -> Blank query -> Advanced editor.
// 3. Paste this in. Set the destination to lh_silver, table
//    `slv_csv_transactions`, replace (not append), and turn OFF "use automatic
//    settings" -- on automatic the destination table is dropped and recreated on
//    every refresh, which can take relationships and measures with it.
// 4. Do NOT let this dataflow write any table that the Spark notebook writes.
//    Fabric Spark writes Delta reader 3 / writer 7; Dataflow Gen2 writes
//    reader 1 / writer 2. Microsoft documents both and never says whether
//    co-writing one table is safe, so we simply never find out.
//
// WHY A DATAFLOW AND NOT MORE PYSPARK
// -----------------------------------
// Because this is what Power Query is *for*, and because the audience for this
// part of the demo is the analyst who owns the spreadsheet today, not the data
// engineer. Every one of the twelve planted defects below is a visible click in
// the Power Query UI. Doing it in Spark would be correct and unpersuasive.
//
// THE TWELVE DEFECTS, AND WHERE EACH IS HANDLED
// ---------------------------------------------
//   1  three preamble lines .................. Table.Skip(3) before promotion
//   2  three date formats in one column ...... ParseDate
//   3  currency symbols and separators ....... ParseAmount
//   4  accounting negatives "(250.00)" ....... ParseAmount
//   5  TOTAL row at the foot ................. RemoveFooter
//   6  blank line before the total ........... RemoveFooter
//   7  inconsistent state casing ............. CleanState
//   8  one transaction present twice ......... flagged, NOT silently deduped
//   9  three spellings of missing ............ Blank
//  10  CRLF line endings ..................... Csv.Document + Blank strip \r
//  11  "End of Report" trailer ............... RemoveFooter
//  12  as-at date only in the filename ....... source_period, from [Name]
//
// Defect 8 is deliberately *flagged rather than fixed*. The two rows are
// byte-for-byte identical, so there is no technical key that says which is real.
// Dropping one silently would be exactly the behaviour this demo criticises.
// `is_duplicate_key` lets the report show the $105.80 gap instead of hiding it.

let
    // ---------------------------------------------------------------- helpers

    // Three formats in one column, and nothing in the file says which is which.
    // 03/04/2019 is 3 April in London and 4 March in Redmond -- for a
    // UK-regulated entity that is a reportable error, and it is silent.
    // We assume UK day-first because the source is a UK bank. That assumption is
    // stated here rather than left implicit in somebody's locale setting.
    ParseDate = (t as nullable text) as nullable date =>
        let
            s = Text.Trim(t ?? ""),
            result =
                if s = "" then null
                else if Text.Contains(s, "/") then
                    try Date.FromText(s, [Format = "dd/MM/yyyy", Culture = "en-GB"])
                        otherwise null
                else if Text.Length(s) = 10 and Text.Contains(s, "-")
                        and (try Number.FromText(Text.Start(s, 4)) otherwise null) <> null then
                    try Date.FromText(s, [Format = "yyyy-MM-dd", Culture = "en-GB"])
                        otherwise null
                else
                    try Date.FromText(s, [Format = "dd-MMM-yyyy", Culture = "en-GB"])
                        otherwise null
        in
            result,

    // "$791.19", "USD 1,204.50", "(250.00)" -- the last is an accounting
    // negative. Parsed naively it becomes a positive, and a refund silently
    // becomes a payment.
    ParseAmount = (t as nullable text) as nullable number =>
        let
            s0 = Text.Trim(t ?? ""),
            isNegative = Text.StartsWith(s0, "(") and Text.EndsWith(s0, ")"),
            s1 = if isNegative then Text.Middle(s0, 1, Text.Length(s0) - 2) else s0,
            s2 = Text.Replace(Text.Replace(s1, "USD", ""), "$", ""),
            s3 = Text.Remove(s2, {",", " ", Character.FromNumber(13),
                                  Character.FromNumber(160)}),
            n = if s3 = "" then null else (try Number.FromText(s3) otherwise null),
            result = if n = null then null else (if isNegative then -n else n)
        in
            result,

    // '', 'N/A' and 'NULL' are three different spellings of missing, none of
    // which is null. A GROUP BY on this column produces three kinds of nothing.
    // The \r strip is defect 10: CRLF leaves a stray carriage return riding on
    // the last column of every row.
    Blank = (t as nullable text) as nullable text =>
        let
            s = Text.Trim(Text.Replace(t ?? "", Character.FromNumber(13), "")),
            result = if List.Contains({"", "N/A", "NULL", "NA", "-"}, Text.Upper(s))
                     then null else s
        in
            result,

    // 'ca', ' NY', 'OH ' are one state each, not three.
    CleanState = (t as nullable text) as nullable text =>
        let
            s = Blank(t),
            result = if s = null then null
                     else if Text.Length(Text.Trim(s)) = 2 then Text.Upper(Text.Trim(s))
                     else Text.Proper(Text.Trim(s))
        in
            result,

    // ------------------------------------------------------------ the source

    Source = AzureStorage.DataLake(
        "https://onelake.dfs.fabric.microsoft.com/nbki-db2-demo/lh_bronze.Lakehouse/Files/csv_drop"),

    OnlyCsv = Table.SelectRows(Source, each Text.EndsWith([Name], ".csv")),

    Parsed = Table.AddColumn(OnlyCsv, "Parsed", each
        let
            raw = Csv.Document([Content], [Delimiter = ",", Encoding = 65001,
                                           QuoteStyle = QuoteStyle.Csv]),
            // Defect 1: three preamble lines above the header. Any reader that
            // assumes row 1 is the header gets one column of garbage.
            skipped = Table.Skip(raw, 3),
            promoted = Table.PromoteHeaders(skipped, [PromoteAllScalars = true])
        in
            promoted),

    // Defect 12: the as-at period exists ONLY in the filename. It is lifted into
    // a column at the first opportunity, before anything can lose it.
    WithFile = Table.AddColumn(Parsed, "SourceFile", each [Name], type text),

    Expanded = Table.ExpandTableColumn(
        Table.SelectColumns(WithFile, {"SourceFile", "Parsed"}), "Parsed",
        {"Transaction Ref", "Posting Date", "Customer No", "Card No", "Card Brand",
         "Card Type", "Amount (USD)", "Entry Method", "Merchant", "Merchant City",
         "Merchant State", "Merchant Zip", "MCC", "Customer Age", "Credit Score",
         "Notes"}),

    // Defects 5, 6 and 11: a TOTAL row, a blank line, and "End of Report".
    // A lazy parser stops at the blank line and silently truncates; a blind
    // ingest double-counts the month by the value of the TOTAL row.
    RemoveFooter = Table.SelectRows(Expanded, each
        [Transaction Ref] <> null
        and Text.Trim([Transaction Ref]) <> ""
        and Text.Upper(Text.Trim([Transaction Ref])) <> "TOTAL"
        and not Text.StartsWith(Text.Upper(Text.Trim([Transaction Ref])), "END OF REPORT")
        and (try Number.FromText(Text.Trim([Transaction Ref])) otherwise null) <> null),

    // ------------------------------------------------------------ conforming

    Typed = Table.AddColumn(RemoveFooter, "rec", each [
        transaction_id = Int64.From(Text.Trim([Transaction Ref])),
        txn_date       = ParseDate([Posting Date]),
        customer_id    = try Int64.From(Blank([Customer No])) otherwise null,
        card_last4     = Blank([Card No]),
        card_brand     = Blank([Card Brand]),
        card_type      = Blank([Card Type]),
        amount         = ParseAmount([Amount (USD)]),
        channel        = Blank([Entry Method]),
        merchant_id    = try Int64.From(Blank([Merchant])) otherwise null,
        merchant_city  = Blank([Merchant City]),
        merchant_state = CleanState([Merchant State]),
        mcc_code       = Blank([MCC]),
        source_period  = Text.BetweenDelimiters([SourceFile], "Equation_Extract_", ".csv")
    ]),

    Flat = Table.ExpandRecordColumn(
        Table.SelectColumns(Typed, {"rec"}), "rec",
        {"transaction_id", "txn_date", "customer_id", "card_last4", "card_brand",
         "card_type", "amount", "channel", "merchant_id", "merchant_city",
         "merchant_state", "mcc_code", "source_period"}),

    // Defect 8: one transaction present twice, identical in every field.
    // Flagged, not dropped -- see the note at the top of this file.
    Counted = Table.Group(Flat, {"transaction_id"},
        {{"n", each Table.RowCount(_), Int64.Type},
         {"rows", each _, type table}}),

    Marked = Table.AddColumn(Counted, "is_duplicate_key", each [n] > 1, type logical),

    Final = Table.ExpandTableColumn(
        Table.SelectColumns(Marked, {"is_duplicate_key", "rows"}), "rows",
        {"transaction_id", "txn_date", "customer_id", "card_last4", "card_brand",
         "card_type", "amount", "channel", "merchant_id", "merchant_city",
         "merchant_state", "mcc_code", "source_period"}),

    Result = Table.TransformColumnTypes(Final, {
        {"transaction_id", Int64.Type}, {"txn_date", type date},
        {"customer_id", Int64.Type}, {"amount", type number},
        {"merchant_id", Int64.Type}})
in
    Result

// ===========================================================================
// SECOND QUERY — MccCodes -> lh_silver.slv_mcc_codes
// ===========================================================================
// A 109-row reference table, and the whole point is that it is boring: the
// low-code tool doing an unremarkable job, next to the same tool untangling a
// deliberately awful CSV. Both are Dataflow Gen2; only one of them is hard.
//
// This reads the bronze Delta table rather than Db2 directly, because the Db2
// connector needs the on-premises gateway and a gateway-backed dataflow drags
// in a separate set of staging constraints for no benefit here.
//
// let
//     Source = Lakehouse.Contents([CreateNavigationProperties = false]),
//     ws = Source{[workspaceId = "5c84bcc5-f497-4eac-b59b-5c2a36bec619"]}[Data],
//     lh = ws{[lakehouseId = "56ba34ce-c8c8-467e-a1a9-8952b7b03dba"]}[Data],
//     tbl = lh{[Id = "MCC_CODES", ItemKind = "Table"]}[Data],
//     Trimmed = Table.TransformColumns(tbl, {
//         {"MCC_CODE", Text.Trim, type text},
//         {"MCC_DESCRIPTION", Text.Trim, type text}}),
//     Renamed = Table.RenameColumns(Trimmed, {
//         {"MCC_CODE", "mcc_code"}, {"MCC_DESCRIPTION", "mcc_description"}}),
//     Final = Table.SelectColumns(Renamed, {"mcc_code", "mcc_description"})
// in
//     Final
