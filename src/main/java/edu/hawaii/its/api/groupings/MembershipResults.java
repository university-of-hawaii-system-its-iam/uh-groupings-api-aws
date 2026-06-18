package edu.hawaii.its.api.groupings;

import java.util.ArrayList;
import java.util.List;

import edu.hawaii.its.api.type.MembershipResult;

public class MembershipResults implements MemberResults<MembershipResult> {
    private String resultCode;
    private List<MembershipResult> results;

    public MembershipResults() {
        setResults(new ArrayList<>());
        setResultCode("FAILURE");
    }

    public MembershipResults(List<MembershipResult> results) {
        setResults(results);
        setResultCode(resultCode);
    }

    public String getResultCode() {
        return resultCode;
    }

    @Override
    public List<MembershipResult> getResults() {
        return results;
    }

    private void setResultCode(String resultCode) {
        this.resultCode = resultCode;
    }

    private void setResults(List<MembershipResult> results) {
        this.results = results;
        setResultCode("SUCCESS");
    }
}