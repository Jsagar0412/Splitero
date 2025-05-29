public class OpportunityWorksheetTriggerHandler extends TriggerHandler{
    @TestVisible
    private static ApplicationDB applicationDBInstance = new ApplicationDB();
    @TestVisible
    private static HomeownerIdentityDB homeownerIdentityDBInstance = new HomeownerIdentityDB();
    @TestVisible
    private static IdDB idDBInstance = new IdDB();
    @TestVisible
    private static OpportunityDB opportunityDBInstance = new OpportunityDB();
    @TestVisible
    private static EquityShareCalcVersionDB calcVersionDBInstance = new EquityShareCalcVersionDB();
    @TestVisible
    private static RelatedFilesDB relatedFilesDBInstance = new RelatedFilesDB();
    @TestVisible
    private static IneligibleReasonDB ineligibleReasonDBInstance = new IneligibleReasonDB();
    @TestVisible
    private static PrimeRateConfigDB primeRateConfigDBInstance = new PrimeRateConfigDB();
    @TestVisible
    private static TriggerParameters triggerParams = new TriggerParameters();
    @TestVisible
    private static OpportunityWorksheetDB opportunityWorksheetDBInstance = new OpportunityWorksheetDB();
    @TestVisible
    private static MortgageStatementDB mortgageStatementDBInstance = new MortgageStatementDB();
    @TestVisible
    private static UELogsDB ueLogsDBInstance = new UELogsDB();
    @TestVisible
    private static UESourceOfTruthLogsDB ueSourceOfTruthLogsDBInstance = new UESourceOfTruthLogsDB();
    @TestVisible
    private static UECompareLogsDB ueCompareLogsDBInstance = new UECompareLogsDB();
    public override void beforeInsert(List<SObject> newList){
        List<Equity_Share_Calculator_Version__c> activeCalc = calcVersionDBInstance.getActiveCalculatorVersion();
        List<Prime_Rate_Configuration__c> primeRateList = primeRateConfigDBInstance.getActivePrimeRateConfig();

        for (Opportunity_Worksheet__c oppWorksheet : (List<Opportunity_Worksheet__c>)newList){
            updateCalcVersion(oppWorksheet, activeCalc);
            setPrimeRate(oppWorksheet, primeRateList);
        }
    }

    public override void afterInsert(List<SObject> newList){

        for (Opportunity_Worksheet__c oppWorksheet : (List<Opportunity_Worksheet__c>)newList){
            getOppIdsSetOppWorksheet(oppWorksheet);
            getOppWorksheetsWithIneligibleReasons(oppWorksheet, null);
            getApplicationIds(oppWorksheet, null);
            getUnderWritingEngineFields(oppWorksheet, null, 'UE_SOT_Fields');
            getUnderWritingEngineFields(oppWorksheet, null, 'UE_Compare_Fields');
        }

        if (!triggerParams.oppWorksheetByOppId.isEmpty()){
            List<Opportunity> opps = opportunityDBInstance.getOpportunitiesById(triggerParams.oppWorksheetByOppId.keySet());
            createIdRecords(opps);
        }

        updateApplication();
        queryOppsAndEnqueuDynamicTaskJob();
        processIneligibleReasonRecords();
        processUELogRecords(true);
        processUELogRecords(false);

        opportunityDBInstance.executeUpdates();
        applicationDBInstance.executeUpdates();
        ineligibleReasonDBInstance.executeInserts();
        ineligibleReasonDBInstance.executeDeletes();
        ueSourceOfTruthLogsDBInstance.executeUpdates();
        ueCompareLogsDBInstance.executeUpdates();
        clearTriggerParams();
    }

    public override void beforeUpdate(List<SObject> newList, Map<Id, SObject> oldMap){
        Map<Id, Opportunity_Worksheet__c> oldOppWorksheetMap = (Map<Id, Opportunity_Worksheet__c>)oldMap;

        for (Opportunity_Worksheet__c oppWorksheet : (List<Opportunity_Worksheet__c>)newList){
            Opportunity_Worksheet__c oldoppWorksheet = oldOppWorksheetMap.get(oppWorksheet.Id);

            getOppWorksheetForSeniorLienType(oppWorksheet, oldoppWorksheet);
        }

        updateSeniorLienType();
        clearTriggerParams();
    }

    public override void afterUpdate(List<SObject> newList, Map<Id, SObject> oldMap){
        Map<Id, Opportunity_Worksheet__c> oldOppWorksheetMap = (Map<Id, Opportunity_Worksheet__c>)oldMap;

        for (Opportunity_Worksheet__c oppWorksheet : (List<Opportunity_Worksheet__c>)newList){
            Opportunity_Worksheet__c oldoppWorksheet = oldOppWorksheetMap.get(oppWorksheet.Id);

            getApplicationIds(oppWorksheet, oldoppWorksheet);
            checkForDynamicTaskFieldChange(oppWorksheet, oldoppWorksheet);
            checkForAVMAcceptableUpdate(oppWorksheet, oldoppWorksheet);
            getOppWorksheetsWithIneligibleReasons(oppWorksheet, oldoppWorksheet);
            getUnderWritingEngineFields(oppWorksheet, oldoppWorksheet, 'UE_SOT_Fields');
            getUnderWritingEngineFields(oppWorksheet, oldoppWorksheet, 'UE_Compare_Fields');
            getOppWorksheetsWithPostGresSync(oppWorksheet, oldoppWorksheet);
        }

        updateApplication();
        queryOppsAndEnqueuDynamicTaskJob();
        processIneligibleReasonRecords();
        processUELogRecords(true);
        processUELogRecords(false);

        Feature_Flag__mdt softCreditFlag = Feature_Flag__mdt.getInstance('Soft_Credit');
        if (softCreditFlag != null && softCreditFlag.Is_Active__c && !Test.isRunningTest()){
            SoftCreditService.callSoftCreditEndpoint(triggerParams.oppWorksheetsForSoftCredit);
        }

        opportunityDBInstance.executeUpdates();
        ineligibleReasonDBInstance.executeInserts();
        ineligibleReasonDBInstance.executeDeletes();
        ueSourceOfTruthLogsDBInstance.executeUpdates();
        ueCompareLogsDBInstance.executeUpdates();
        clearTriggerParams();
    }

    private void setPrimeRate(Opportunity_Worksheet__c oppWorksheet, List<Prime_Rate_Configuration__c> primeRateList){
        if (oppWorksheet.Prime_Rate__c == null){
            oppWorksheet.Prime_Rate__c = !primeRateList.isEmpty() ? primeRateList[0].Prime_Rate__c : 0;
        }
    }

    private void getApplicationIds(Opportunity_Worksheet__c oppWorksheet, Opportunity_Worksheet__c oldoppWorksheet){
        if (oppWorksheet.Application__c != null && (oldoppWorksheet == null || oldoppWorksheet.Application__c == null)){
            triggerParams.oppWorksheetByAppId.put(oppWorksheet.Application__c, oppWorksheet);
        }
    }

    private void updateApplication(){
        if (triggerParams.oppWorksheetByAppId.isEmpty()){
            return;
        }

        List<Application__c> apps = applicationDBInstance.getApplicationsById(triggerParams.oppWorksheetByAppId.keySet());

        Map<Id, Application__c> applicationsByOppWorksheetId = new Map<Id, Application__c>();
        for (Application__c app : apps){
            app.Opportunity_Worksheet__c = triggerParams.oppWorksheetByAppId.get(app.Id).Id;
            applicationDBInstance.addUpdate(app);
        }
    }

    private void updateCalcVersion(Opportunity_Worksheet__c oppWorksheet, List<Equity_Share_Calculator_Version__c> activeCalc){
        if (!activeCalc.isEmpty()){
            oppWorksheet.Equity_Share_Calculator_Version__c = activeCalc[0].Id;
        }
    }

    private void getOppWorksheetsWithIneligibleReasons(Opportunity_Worksheet__c oppWorksheet, Opportunity_Worksheet__c oldOppWorksheet){
        if (oldOppWorksheet == null || oppWorksheet.Total_NOD_NOS_All_Time__c != oldOppWorksheet.Total_NOD_NOS_All_Time__c || oppWorksheet.Bankruptcy_Seasoning__c != oldOppWorksheet.Bankruptcy_Seasoning__c || oppWorksheet.Foreclosure_Seasoning__c != oldOppWorksheet.Foreclosure_Seasoning__c || oppWorksheet.Investment_Position__c != oldOppWorksheet.Investment_Position__c || oppWorksheet.NOD_in_past_12_months__c != oldOppWorksheet.NOD_in_past_12_months__c || oppWorksheet.NOS_in_past_12_months__c != oldOppWorksheet.NOS_in_past_12_months__c || oppWorksheet.NOS_in_past_36_months__c != oldOppWorksheet.NOS_in_past_36_months__c || oppWorksheet.NOS_in_past_36_months__c != oldOppWorksheet.NOS_in_past_36_months__c || oppWorksheet.Initial_Appraised_Value_Source__c != oldOppWorksheet.Initial_Appraised_Value_Source__c || oppWorksheet.Final_AVM_Price__c != oldOppWorksheet.Final_AVM_Price__c || oppWorksheet.Final_Hybrid_Value__c != oldOppWorksheet.Final_Hybrid_Value__c || oppWorkSheet.Investment_Amount__c != oldOppWorksheet.Investment_Amount__c){
            triggerParams.oppWSForIneligibleReasons.put(oppWorksheet.Id, oppWorksheet);
        }
    }

    private void createIdRecords(List<Opportunity> opps){
        Map<Id, Opportunity> oppsByPortalUserIds = new Map<Id, Opportunity>();
        Map<Id, Opportunity> oppsByS3Files = new Map<Id, Opportunity>();
        Map<Id, Opportunity> oppsByOppWorksheetId = new Map<Id, Opportunity>();

        for (Opportunity opp : opps){
            if (opp.Lead__r.Portal_User__c != null){
                oppsByPortalUserIds.put(opp.Lead__r.Portal_User__c, opp);
            }

            if (!opp.Documents__r.isEmpty() && opp.Documents__r[0].Amazon_S3_File__c != null){
                oppsByS3Files.put(opp.Documents__r[0].Amazon_S3_File__c, opp);
            }
        }

        List<Homeowner_Identity__c> homeownerIds = homeownerIdentityDBInstance.getHomeownerIdsFromContactIds(oppsByPortalUserIds.keySet());
        Map<Id, List<Homeowner_Identity__c>> homeownerIdsByPortalUserId = GeneralHelper.getMapOfIdToListSObj('Portal_User__c', homeownerIds);

        List<Related_Files__c> relatedFiles = relatedFilesDBInstance.getRelatedFilesByS3Id(oppsByS3Files.keySet());
        Map<Id, SObject> relatedFilesByS3Id = GeneralHelper.getMapOfSObjectByField('Amazon_S3_File__c', relatedFiles);

        Set<Id> oppWorksheetIds = new Set<Id>();

        for (Id hoId : homeownerIdsByPortalUserId.keySet()){
            Homeowner_Identity__c homeownerId = homeownerIdsByPortalUserId.get(hoId)[0];
            Opportunity opp = (Opportunity) oppsByPortalUserIds.get(homeownerId.Portal_User__c);
            Opportunity_Worksheet__c oppWorksheet = triggerParams.oppWorksheetByOppId.get(opp.Id);
            oppsByOppWorksheetId.put(oppWorksheet.Id, opp);

            Id__c newId = Ids.createIdFromHomeownerId(homeownerId, oppWorksheet);
            idDBInstance.addInsert(newId);

            oppWorksheetIds.add(oppWorksheet.Id);
        }

        idDBInstance.executeInserts();

        List<Id__c> insertedIds = idDBInstance.getIdsByOppWorksheetIds(oppWorksheetIds);

        for (Id__c insertedId : insertedIds){
            Opportunity opp = oppsByOppWorksheetId.get(insertedId.Opportunity_Worksheet__c);

            if (!opp.Documents__r.isEmpty() && opp.Documents__r[0].Amazon_S3_File__c != null && relatedFilesByS3Id.get(opp.Documents__r[0].Amazon_S3_File__c) != null){
                Related_Files__c relatedFile = (Related_Files__c) relatedFilesByS3Id.get(opp.Documents__r[0].Amazon_S3_File__c);
                relatedFile.Id__c = insertedId.Id;
                relatedFilesDBInstance.addUpdate(relatedFile);
            }
        }

        relatedFilesDBInstance.executeUpdates();
    }

    @TestVisible
    private void getOppIdsSetOppWorksheet(Opportunity_Worksheet__c oppWorksheet){
        if (oppWorksheet.Opportunity__c != null){
            triggerParams.oppWorksheetByOppId.put(oppWorksheet.Opportunity__c, oppWorksheet);

            Opportunity opp = new Opportunity();
            opp.Id = oppWorksheet.Opportunity__c;
            opp.Opportunity_Worksheet__c = oppWorksheet.Id;
            opportunityDBInstance.addUpdate(opp);
        }
    }

    @TestVisible
    private void checkForDynamicTaskFieldChange(Opportunity_Worksheet__c oppWorksheet, Opportunity_Worksheet__c oldoppWorksheet){
        List<Schema.FieldSetMember> fields = Schema.SObjectType.Opportunity_Worksheet__c.fieldSets.getMap().get('Dynamic_Task_Fields').getFields();

        for (Schema.FieldSetMember field : fields){
            String fieldAPIName = field.getSObjectField().getDescribe().getName();
            if (oppWorksheet.get(fieldAPIName) != oldoppWorksheet.get(fieldAPIName) && oppWorksheet.Opportunity__c != null){
                triggerParams.oppWorksheetByOppId.put(oppWorksheet.Opportunity__c, oppWorksheet);
                return;
            }
        }
    }

    @TestVisible
    private void queryOppsAndEnqueuDynamicTaskJob(){
        List<Opportunity> opps = new List<Opportunity>();
        if (!triggerParams.oppWorksheetByOppId.isEmpty()){
            opps = opportunityDBInstance.getOppsById(triggerParams.oppWorksheetByOppId.keySet());
            System.enqueueJob(new DynamicTaskJob(opps, triggerParams.oppWorksheetByOppId, 'Opportunity_Worksheet__c'));
        }
    }

    private void checkForAVMAcceptableUpdate(Opportunity_Worksheet__c oppWorksheet, Opportunity_Worksheet__c oldoppWorksheet){
        if (oppWorksheet.AVM_Acceptable_Calculated__c == 'No' && oldoppWorksheet.AVM_Acceptable_Calculated__c != 'No'){
            Opportunity opp = new Opportunity();
            opp.Id = oppWorksheet.Opportunity__c;
            opp.Hybrid_Appraisal_Required__c = 'Yes';
            opportunityDBInstance.addUpdate(opp);
        }
    }

    private void processIneligibleReasonRecords(){
        if (triggerParams.oppWSForIneligibleReasons.isEmpty()){
            return;
        }

        Map<Id, List<SObject>> oppWSsByOppId = GeneralHelper.getMapOfIdToListSObj('Opportunity__c', triggerParams.oppWSForIneligibleReasons.values());
        List<Ineligible_Reason_Object__c> existingIneligibleReasons = ineligibleReasonDBInstance.getIneligibleReasonsByOppId(oppWSsByOppId.keySet());
        Map<Id, List<String>> ineligibleReasonNamesByOppId = GeneralHelper.getMapOfIdToListString('Opportunity__c', 'Name', existingIneligibleReasons);

        Map<String, SObject> ineligibleReasonsByName = GeneralHelper.getMapOfSObjectByFieldString('Name', existingIneligibleReasons);

        for (Opportunity_Worksheet__c oppWS : triggerParams.oppWSForIneligibleReasons.values()){
            List<String> existingIneligibleReasonForOpp = !existingIneligibleReasons.isEmpty() ? ineligibleReasonNamesByOppId.get(oppWS.Opportunity__c) : new List<String>();

            if (oppWS.NOD_in_past_12_months__c > 2 && !existingIneligibleReasonForOpp.contains('ISL2')){
                Ineligible_Reason__mdt mdtInstance = Ineligible_Reason__mdt.getInstance('ISL2');
                addIneligibleReason(mdtInstance, oppWS.Opportunity__c);
            } else if ((oppWS.NOD_in_past_12_months__c == null || oppWS.NOD_in_past_12_months__c <= 2) && existingIneligibleReasonForOpp.contains('ISL2')){
                ineligibleReasonDBInstance.addDelete((Ineligible_Reason_Object__c) ineligibleReasonsByName.get('ISL2'));
            }

            if (oppWS.NOS_in_past_12_months__c > 0 && !existingIneligibleReasonForOpp.contains('ISL3')){
                Ineligible_Reason__mdt mdtInstance = Ineligible_Reason__mdt.getInstance('ISL3');
                addIneligibleReason(mdtInstance, oppWS.Opportunity__c);
            } else if ((oppWS.NOS_in_past_12_months__c == null || oppWS.NOS_in_past_12_months__c <= 0) && existingIneligibleReasonForOpp.contains('ISL3')){
                ineligibleReasonDBInstance.addDelete((Ineligible_Reason_Object__c) ineligibleReasonsByName.get('ISL3'));
            }

            if (oppWS.NOS_in_past_36_months__c > 1 && !existingIneligibleReasonForOpp.contains('ISL9')){
                Ineligible_Reason__mdt mdtInstance = Ineligible_Reason__mdt.getInstance('ISL9');
                addIneligibleReason(mdtInstance, oppWS.Opportunity__c);
            } else if ((oppWS.NOS_in_past_36_months__c == null || oppWS.NOS_in_past_36_months__c <= 1) && existingIneligibleReasonForOpp.contains('ISL9')){
                ineligibleReasonDBInstance.addDelete((Ineligible_Reason_Object__c) ineligibleReasonsByName.get('ISL9'));
            }

            if (oppWS.Bankruptcy_Seasoning__c == 'Ineligible' && !existingIneligibleReasonForOpp.contains('BK1')){
                Ineligible_Reason__mdt mdtInstance = Ineligible_Reason__mdt.getInstance('BK1');
                addIneligibleReason(mdtInstance, oppWS.Opportunity__c);
            } else if (oppWS.Bankruptcy_Seasoning__c != 'Ineligible' && existingIneligibleReasonForOpp.contains('BK1')){
                ineligibleReasonDBInstance.addDelete((Ineligible_Reason_Object__c) ineligibleReasonsByName.get('BK1'));
            }

            if (oppWS.Foreclosure_Seasoning__c == 'Ineligible' && !existingIneligibleReasonForOpp.contains('FC1')){
                Ineligible_Reason__mdt mdtInstance = Ineligible_Reason__mdt.getInstance('FC1');
                addIneligibleReason(mdtInstance, oppWS.Opportunity__c);
            } else if (oppWS.Foreclosure_Seasoning__c != 'Ineligible' && existingIneligibleReasonForOpp.contains('FC1')){
                ineligibleReasonDBInstance.addDelete((Ineligible_Reason_Object__c) ineligibleReasonsByName.get('FC1'));
            }

            Integer investmentPosition = oppWS.Investment_Position__c != null ? Integer.valueOf(oppWS.Investment_Position__c) : 0;
            Integer maxLienPosition = (oppWS.Equity_Share_Calculator_Version__r != null && oppWS.Equity_Share_Calculator_Version__r.Lien_Position_Max_HR__c != null) ? Integer.valueOf(oppWS.Equity_Share_Calculator_Version__r.Lien_Position_Max_HR__c) : 2;
            if (investmentPosition > maxLienPosition && !existingIneligibleReasonForOpp.contains('ISL4')){
                Ineligible_Reason__mdt mdtInstance = Ineligible_Reason__mdt.getInstance('ISL4');
                addIneligibleReason(mdtInstance, oppWS.Opportunity__c);
            } else if (investmentPosition <= 2 && existingIneligibleReasonForOpp.contains('ISL4')){
                ineligibleReasonDBInstance.addDelete((Ineligible_Reason_Object__c) ineligibleReasonsByName.get('ISL4'));
            }


            Decimal initialAppraisedValue = 0.0;
            if (oppWS.Initial_Appraised_Value_Source__c == 'AVM'){
                initialAppraisedValue = oppWS.Final_AVM_Price__c != null ? oppWS.Final_AVM_Price__c : 0.0;
            } else if (oppWS.Initial_Appraised_Value_Source__c == 'Hybrid Appraisal'){
                initialAppraisedValue = oppWS.Final_Hybrid_Value__c != null ? oppWS.Final_Hybrid_Value__c : 0.0;
            }

            Decimal investmentAmount = oppWS.Investment_Amount__c != null ? oppWS.Investment_Amount__c : 0.0;

            if (investmentAmount > 0 && initialAppraisedValue > 0 && (initialAppraisedValue / investmentAmount) < 0.1 && !existingIneligibleReasonForOpp.contains('IE2')){
                Ineligible_Reason__mdt mdtInstance = Ineligible_Reason__mdt.getInstance('IE2');
                addIneligibleReason(mdtInstance, oppWS.Opportunity__c);
            } else if ((initialAppraisedValue == 0 || investmentAmount == 0 || initialAppraisedValue / investmentAmount > 0.1) && existingIneligibleReasonForOpp.contains('IE2')){
                ineligibleReasonDBInstance.addDelete((Ineligible_Reason_Object__c) ineligibleReasonsByName.get('IE2'));
            }
        }
    }

    private static void addIneligibleReason(Ineligible_Reason__mdt irMDT, Id oppId){
        Ineligible_Reason_Object__c newIneligibleReason = IneligibleReasons.createIneligibleDocument(irMDT, oppId);
        ineligibleReasonDBInstance.addInsert(newIneligibleReason);
    }

    private void processUELogRecords(Boolean isSourceOfTruth){

        Map<Id, List<Map<String, String>>> fieldMaps = isSourceOfTruth ? triggerParams.ueSourceOfTruthFieldsMaps : triggerParams.ueCompareFieldsMaps;

        if (fieldMaps.isEmpty())
            return;
        List<Opportunity_Worksheet__c> oppWorksheets = opportunityWorksheetDBInstance.getOppByOppWorksheetIds(fieldMaps.keySet());
        if (oppWorksheets.isEmpty())
            return;
        Set<Id> opportunityIds = new Set<Id>();
        for (Opportunity_Worksheet__c worksheet : oppWorksheets){
            opportunityIds.add(worksheet.Opportunity__c);
        }

        List<sObject> logs = isSourceOfTruth ? (List<sObject>)ueSourceOfTruthLogsDBInstance.getSourceOfTruthFieldLogs(opportunityIds, 'Opportunity_Worksheet__c') : (List<sObject>)ueCompareLogsDBInstance.getCompareFieldLogs(opportunityIds, 'Opportunity_Worksheet__c');

        if (logs.isEmpty())
            return;
        Map<Id, List<sObject>> logMap = GeneralHelper.getMapOfIdToListSObj('Opportunity__c', logs);
        List<sObject> recordsToUpdate = new List<sObject>();

        for (Opportunity_Worksheet__c worksheet : oppWorksheets){
            if (logMap.containsKey(worksheet.Opportunity__c)){
                recordsToUpdate.addAll(isSourceOfTruth ? UnderwritingEngineLogHelper.getSourceOfTruthLogRecordsForUpdate(logMap.get(worksheet.Opportunity__c), fieldMaps.get(worksheet.Id)) : UnderwritingEngineLogHelper.getCompareLogRecordsForUpdate(logMap.get(worksheet.Opportunity__c), fieldMaps.get(worksheet.Id)));
            }
        }

        if (recordsToUpdate.isEmpty())
            return;
        recordsToUpdate.sort ();
        if (isSourceOfTruth){
            ueSourceOfTruthLogsDBInstance.addUpdates(recordsToUpdate);
        } else{
            ueCompareLogsDBInstance.addUpdates(recordsToUpdate);
        }
    }

    @TestVisible
    private void getUnderWritingEngineFields(Opportunity_Worksheet__c oppWorkSheet, Opportunity_Worksheet__c oldOppWorksheet, String fieldSetName){
        if (oppWorkSheet.Opportunity__c == null)
            return;
        List<Schema.FieldSetMember> fieldSetMembers = Schema.SObjectType.Opportunity_Worksheet__c.fieldSets.getMap().get(fieldSetName).getFields();
        if (fieldSetName.equals('UE_SOT_Fields')){
            GeneralHelper.changedFieldsToTriggerParameter(oppWorksheet.Id, triggerParams.ueSourceOfTruthFieldsMaps, fieldSetMembers, oppWorkSheet, oldOppWorksheet);
        } else if (fieldSetName.equals('UE_Compare_Fields')){
            GeneralHelper.changedFieldsToTriggerParameter(oppWorksheet.Id, triggerParams.ueCompareFieldsMaps, fieldSetMembers, oppWorkSheet, oldOppWorksheet);
        }
    }

    @TestVisible
    private void getOppWorksheetForSeniorLienType(Opportunity_Worksheet__c oppWorksheet, Opportunity_Worksheet__c oldOppWorksheet){
        Boolean isUpdate = oldOppWorksheet != null && (oppWorksheet.Prime_Rate__c != oldOppWorksheet.Prime_Rate__c);
        Boolean isPrimeRate = oppWorksheet.Prime_Rate__c != null;
        if (isPrimeRate && isUpdate){
            triggerParams.oppWorksheetsForSeniorLienTypeUpdate.put(oppWorksheet.Id, oppWorksheet);
        }
    }

    private static void updateSeniorLienType(){
        if (triggerParams.oppWorksheetsForSeniorLienTypeUpdate.isEmpty()){
            return;
        }
        List<Mortgage_Statement__c> mortgageStatementWithOppWorksheetIds = mortgageStatementDBInstance.getMortgageStatementsByOppWorksheetIds(triggerParams.oppWorksheetsForSeniorLienTypeUpdate.keySet());
        Map<Id, List<Mortgage_Statement__c>> mortgageStatementsByOppWorksheetId = GeneralHelper.getMapOfIdToListSObj('Opportunity_Worksheet__c', mortgageStatementWithOppWorksheetIds);
        for (Opportunity_Worksheet__c oppWorksheet : triggerParams.oppWorksheetsForSeniorLienTypeUpdate.values()){
            List<Mortgage_Statement__c> mortgageStatements = mortgageStatementsByOppWorksheetId.get(oppWorksheet.Id);
            if (mortgageStatements != null && mortgageStatements.size() > 0){
                for (Mortgage_Statement__c mortgageStatement : mortgageStatements){
                    if (String.isBlank(mortgageStatement.Mortgage_Payoff_Required_or_Requested__c) || mortgageStatement.Mortgage_Payoff_Required_or_Requested__c == 'No'){
                        oppWorksheet.Senior_Lien_Type__c = 'ATypical';
                        break;
                    } else if (mortgageStatement.Is_Private_Mortgage__c != 'Yes' || mortgageStatement.Interest_Rate__c != null && oppWorksheet.Prime_Rate__c != null && ((oppWorksheet.Prime_Rate__c + 4.00) >= mortgageStatement.Interest_Rate__c)){
                        oppWorksheet.Senior_Lien_Type__c = 'Typical';
                        break;
                    }
                }
            }
        }
    }

    @TestVisible
    private void getOppWorksheetsWithPostGresSync(Opportunity_Worksheet__c opp, Opportunity_Worksheet__c oldOpp){
        if (opp.postgres_sync__c == true && (oldOpp == null || opp.postgres_sync__c != oldOpp.postgres_sync__c)){
            triggerParams.oppWorksheetsForSoftCredit.add(opp.Id);
        }
    }

    private void clearTriggerParams(){
        triggerParams.oppWorksheetByOppId.clear();
        triggerParams.oppWSForIneligibleReasons.clear();
        triggerParams.oppWorksheetByAppId.clear();
        triggerParams.ueSourceOfTruthFieldsMaps.clear();
        triggerParams.ueCompareFieldsMaps.clear();
        triggerParams.oppWorksheetsForSeniorLienTypeUpdate.clear();
        triggerParams.oppWorksheetsForSoftCredit.clear();
    }

    @TestVisible
    private class TriggerParameters{
        @TestVisible
        Map<Id, Opportunity_Worksheet__c> oppWorksheetByOppId = new Map<Id, Opportunity_Worksheet__c>();
        Map<Id, Opportunity_Worksheet__c> oppWSForIneligibleReasons = new Map<Id, Opportunity_Worksheet__c>();
        Map<Id, Opportunity_Worksheet__c> oppWorksheetByAppId = new Map<Id, Opportunity_Worksheet__c>();
        Map<Id, List<Map<String, String>>> ueSourceOfTruthFieldsMaps = new Map<Id, List<Map<String, String>>>();
        Map<Id, List<Map<String, String>>> ueCompareFieldsMaps = new Map<Id, List<Map<String, String>>>();
        Map<Id, Opportunity_Worksheet__c> oppWorksheetsForSeniorLienTypeUpdate = new Map<Id, Opportunity_Worksheet__c>();
        Set<Id> oppWorksheetsForSoftCredit = new Set<Id>();
    }

}