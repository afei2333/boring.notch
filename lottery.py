import requests

HEADERS = {
    "User-Agent": "Mozilla/5.0",
}

def get_latest_dlt():
    url = (
        "https://webapi.sporttery.cn/gateway/lottery/"
        "getHistoryPageListV1.qry"
    )
    params = {
        "gameNo": "85",
        "provinceId": "0",
        "pageSize": 1,
        "isVerify": 1,
        "pageNo": 1,
    }
    headers = {
        **HEADERS,
        "Referer": "https://www.lottery.gov.cn/",
    }

    data = requests.get(
        url, params=params, headers=headers, timeout=10
    ).json()["value"]["list"][0]

    numbers = data["lotteryDrawResult"].split()

    return {
        "期号": data["lotteryDrawNum"],
        "日期": data["lotteryDrawTime"],
        "前区": numbers[:5],
        "后区": numbers[5:],
    }


def get_latest_ssq():
    url = (
        "https://www.cwl.gov.cn/cwl_admin/front/cwlkj/"
        "search/kjxx/findDrawNotice"
    )
    params = {
        "name": "ssq",
        "issueCount": 1,
        "pageNo": 1,
        "pageSize": 1,
        "systemType": "PC",
    }
    headers = {
        **HEADERS,
        "Referer": "https://www.cwl.gov.cn/",
    }

    data = requests.get(
        url, params=params, headers=headers, timeout=10
    ).json()["result"][0]

    return {
        "期号": data["code"],
        "日期": data["date"],
        "红球": data["red"].split(","),
        "蓝球": [data["blue"]],
    }


print("大乐透：", get_latest_dlt())
print("双色球：", get_latest_ssq())
